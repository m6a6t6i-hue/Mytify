package pl.mytify.mytify

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import java.io.File
import java.net.Proxy
import java.net.URI
import java.net.URL
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import org.json.JSONArray
import org.json.JSONObject

internal fun transferId(s: String) = s.matches(Regex("[0-9a-f]{64}"))

internal data class TransferPeer(
    val host: String,
    val port: Int,
    val pin: String,
    val token: String = "",
    val name: String = "Mytify PC",
) {
    fun json() = obj("host" to host, "port" to port, "pin" to pin, "token" to token, "name" to name)

    companion object {
        fun from(j: JSONObject) =
            TransferPeer(
                j.getString("host"),
                j.getInt("port"),
                j.getString("pin"),
                j.optString("token"),
                j.optString("name", "Mytify PC"),
            )

        fun parse(link: String, allowLoopback: Boolean = false): Pair<TransferPeer, String> {
            require(link.length <= 2048) { "Kod parowania jest za długi" }
            val u = URI(link.trim())
            require(
                u.scheme == "mytify" &&
                    u.host == "pair" &&
                    u.rawFragment == null &&
                    u.rawUserInfo == null &&
                    u.path.orEmpty().isEmpty()
            ) {
                "To nie jest kod Mytify"
            }
            val q =
                u.rawQuery.orEmpty().split('&').associate {
                    val p = it.split('=', limit = 2)
                    require(p.size == 2)
                    p[0] to p[1]
                }
            require(q.size == 5 && q["v"] == "1") { "Nieobsługiwany kod Mytify" }
            val host = q["host"].orEmpty()
            val oct = host.split('.').map { it.toIntOrNull() ?: -1 }
            require(
                oct.size == 4 &&
                    oct.all { it in 0..255 } &&
                    host == oct.joinToString(".") &&
                    ((allowLoopback && host == "127.0.0.1") ||
                        oct[0] == 10 ||
                        (oct[0] == 172 && oct[1] in 16..31) ||
                        (oct[0] == 192 && oct[1] == 168))
            ) {
                "Wybierz komputer w lokalnej sieci Wi-Fi"
            }
            val port = q["port"]?.toIntOrNull() ?: 0
            val pin = q["fingerprint"].orEmpty()
            val secret = q["secret"].orEmpty()
            require(port in 1..65535 && transferId(pin) && transferId(secret)) {
                "Nieprawidłowy kod parowania"
            }
            return TransferPeer(host, port, pin) to secret
        }
    }
}

internal class TransferClient(private val allowLoopback: Boolean = false) {
    @Volatile private var active: HttpsURLConnection? = null

    fun abort() {
        active?.disconnect()
    }

    fun open(
        peer: TransferPeer,
        path: String,
        body: JSONObject? = null,
        offset: Long? = null,
    ): HttpsURLConnection {
        require(path.startsWith('/') && !path.contains('\r') && !path.contains('\n'))
        val trust =
            object : X509TrustManager {
                override fun getAcceptedIssuers() = emptyArray<X509Certificate>()

                override fun checkClientTrusted(c: Array<X509Certificate>, a: String) {
                    throw java.security.cert.CertificateException(
                        "Client certificates not supported"
                    )
                }

                override fun checkServerTrusted(c: Array<X509Certificate>, a: String) {
                    if (
                        c.isEmpty() ||
                            !MessageDigest.isEqual(
                                sha(c[0].encoded).toByteArray(),
                                peer.pin.toByteArray(),
                            )
                    )
                        throw java.security.cert.CertificateException(
                            "Certyfikat PC się zmienił. Sparuj urządzenia ponownie."
                        )
                }
            }
        val ssl = SSLContext.getInstance("TLS")
        ssl.init(null, arrayOf(trust), null)
        val c =
            URL("https://${peer.host}:${peer.port}$path").openConnection(Proxy.NO_PROXY)
                as HttpsURLConnection
        active = c
        c.sslSocketFactory = ssl.socketFactory
        c.hostnameVerifier =
            javax.net.ssl.HostnameVerifier { h, s ->
                h == peer.host &&
                    runCatching { sha(s.peerCertificates[0].encoded) == peer.pin }
                        .getOrDefault(false)
            }
        c.instanceFollowRedirects = false
        c.connectTimeout = 10000
        c.readTimeout = 15000
        if (peer.token.isNotEmpty()) c.setRequestProperty("Authorization", "Bearer ${peer.token}")
        if (offset != null) c.setRequestProperty("Range", "bytes=$offset-")
        if (body != null) {
            val b = body.toString().toByteArray()
            c.requestMethod = "POST"
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            c.setFixedLengthStreamingMode(b.size)
            c.outputStream.use { it.write(b) }
        }
        return c
    }

    fun json(peer: TransferPeer, path: String, body: JSONObject? = null): JSONObject {
        val c = open(peer, path, body)
        try {
            require(c.responseCode == 200) {
                if (c.responseCode == 401 || c.responseCode == 403)
                    "PC odmówił dostępu. Odśwież kod QR i sparuj ponownie."
                else "PC zwrócił błąd ${c.responseCode}"
            }
            return JSONObject(
                c.inputStream.use { readLimited(it, 8 * 1024 * 1024) }.toString(Charsets.UTF_8)
            )
        } finally {
            c.disconnect()
            active = null
        }
    }

    fun pair(link: String): TransferPeer {
        val (peer, secret) = TransferPeer.parse(link, allowLoopback)
        val j = json(peer, "/pair", obj("secret" to secret, "name" to android.os.Build.MODEL))
        require(j.getString("identity") == peer.pin && transferId(j.getString("token"))) {
            "Nieprawidłowa odpowiedź PC"
        }
        return peer.copy(
            token = j.getString("token"),
            name = j.optString("name", "Mytify PC").take(80),
        )
    }

    fun cover(peer: TransferPeer, id: String): ByteArray {
        require(transferId(id))
        val c = open(peer, "/cover/$id")
        try {
            require(c.responseCode == 200)
            val b = c.inputStream.use { readLimited(it, 8 * 1024 * 1024) }
            require(sha(b) == id) { "Nieprawidłowa suma okładki" }
            return b
        } finally {
            c.disconnect()
            active = null
        }
    }

    fun download(
        peer: TransferPeer,
        id: String,
        size: Long,
        part: File,
        cancelled: AtomicBoolean,
        progress: (Long) -> Unit,
    ) {
        require(transferId(id) && size in 1..(20L * 1024 * 1024 * 1024))
        if (part.length() > size) check(part.delete())
        val offset = part.length()
        if (offset < size) {
            val c = open(peer, "/file/$id", offset = if (offset > 0) offset else null)
            try {
                require(c.responseCode == if (offset > 0) 206 else 200) {
                    "Nie można wznowić pliku (${c.responseCode})"
                }
                if (offset > 0)
                    require(c.getHeaderField("Content-Range") == "bytes $offset-${size-1}/$size") {
                        "Plik na PC się zmienił"
                    }
                require(c.getHeaderField("Content-Length")?.toLongOrNull() == size - offset) {
                    "Rozmiar pliku na PC się zmienił. Wykonaj skan na PC."
                }
                c.inputStream.use { input ->
                    java.io.FileOutputStream(part, true).use { output ->
                        val b = ByteArray(128 * 1024)
                        var done = offset
                        while (done < size) {
                            if (cancelled.get()) throw CancellationException("Wstrzymano")
                            val n = input.read(b, 0, minOf(b.size.toLong(), size - done).toInt())
                            check(n > 0) {
                                "Połączenie zostało przerwane. Możesz wznowić pobieranie."
                            }
                            output.write(b, 0, n)
                            done += n
                            progress(done)
                        }
                        output.fd.sync()
                    }
                }
            } finally {
                c.disconnect()
                active = null
            }
        }
        if (cancelled.get()) throw CancellationException("Wstrzymano")
        if (fileHash(part) != id) {
            part.delete()
            error(
                "Suma SHA-256 pliku jest niezgodna. Plik nie został dodany do biblioteki. Wykonaj ponowny skan biblioteki na PC i spróbuj jeszcze raz."
            )
        }
    }

    companion object {
        fun fileHash(f: File): String {
            val d = MessageDigest.getInstance("SHA-256")
            f.inputStream().use {
                val b = ByteArray(128 * 1024)
                while (true) {
                    val n = it.read(b)
                    if (n < 0) break
                    d.update(b, 0, n)
                }
            }
            return d.digest().joinToString("") { "%02x".format(it) }
        }
    }
}

internal interface TransferPeers {
    fun list(): List<TransferPeer>

    fun save(peers: List<TransferPeer>)
}

internal class EncryptedTransferPeers(context: Context) : TransferPeers {
    private val file = AtomicFile(File(context.filesDir, "transfer-peers.sealed"))

    private fun key(): SecretKey {
        val s = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return (s.getKey("mytify-transfer", null) as? SecretKey)
            ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
                .apply {
                    init(
                        KeyGenParameterSpec.Builder(
                                "mytify-transfer",
                                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                            )
                            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                            .build()
                    )
                }
                .generateKey()
    }

    override fun list(): List<TransferPeer> {
        if (!file.baseFile.exists()) return emptyList()
        val j = JSONObject(file.openRead().use { it.readBytes().toString(Charsets.UTF_8) })
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(
            Cipher.DECRYPT_MODE,
            key(),
            GCMParameterSpec(128, Base64.decode(j.getString("iv"), Base64.NO_WRAP)),
        )
        val a =
            JSONArray(
                c.doFinal(Base64.decode(j.getString("data"), Base64.NO_WRAP))
                    .toString(Charsets.UTF_8)
            )
        return (0 until a.length()).map { TransferPeer.from(a.getJSONObject(it)) }
    }

    override fun save(peers: List<TransferPeer>) {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val bytes = c.doFinal(JSONArray(peers.map { it.json() }).toString().toByteArray())
        val j =
            obj(
                "iv" to Base64.encodeToString(c.iv, Base64.NO_WRAP),
                "data" to Base64.encodeToString(bytes, Base64.NO_WRAP),
            )
        val out = file.startWrite()
        try {
            out.write(j.toString().toByteArray())
            file.finishWrite(out)
        } catch (e: Exception) {
            file.failWrite(out)
            throw e
        }
    }
}
