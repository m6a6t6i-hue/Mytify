package pl.mytify.mytify

import android.content.Context
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import org.json.JSONArray
import org.json.JSONObject

/** Where the phone's sharing identity (certificate, key, paired phones) is kept. */
internal interface ShareStore {
    fun load(): JSONObject?

    fun save(value: JSONObject)
}

/** Sealed with an AES key that never leaves the Android keystore. */
internal class EncryptedShareStore(context: Context) : ShareStore {
    private val file = AtomicFile(File(context.filesDir, "share-identity.sealed"))

    private fun key(): SecretKey {
        val s = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return (s.getKey("mytify-share", null) as? SecretKey)
            ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
                .apply {
                    init(
                        KeyGenParameterSpec.Builder(
                                "mytify-share",
                                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                            )
                            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                            .build()
                    )
                }
                .generateKey()
    }

    override fun load(): JSONObject? {
        if (!file.baseFile.exists()) return null
        val j = JSONObject(file.openRead().use { it.readBytes().toString(Charsets.UTF_8) })
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(j.getString("iv"), Base64.NO_WRAP)))
        return JSONObject(c.doFinal(Base64.decode(j.getString("data"), Base64.NO_WRAP)).toString(Charsets.UTF_8))
    }

    override fun save(value: JSONObject) {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val bytes = c.doFinal(value.toString().toByteArray())
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

/** Minimal DER for one self-signed ECDSA P-256 certificate (no extra libraries). */
internal object SelfSigned {
    private fun len(n: Int): ByteArray =
        when {
            n < 0x80 -> byteArrayOf(n.toByte())
            n < 0x100 -> byteArrayOf(0x81.toByte(), n.toByte())
            else -> byteArrayOf(0x82.toByte(), (n shr 8).toByte(), n.toByte())
        }

    private fun tlv(tag: Int, body: ByteArray) = byteArrayOf(tag.toByte()) + len(body.size) + body

    private fun seq(vararg parts: ByteArray) = tlv(0x30, parts.fold(ByteArray(0)) { a, b -> a + b })

    private fun oid(vararg arcs: Int): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(arcs[0] * 40 + arcs[1])
        for (a in arcs.drop(2)) {
            val bytes = mutableListOf<Int>()
            var v = a
            do {
                bytes.add(0, v and 0x7f)
                v = v shr 7
            } while (v > 0)
            bytes.forEachIndexed { i, b -> out.write(if (i < bytes.size - 1) b or 0x80 else b) }
        }
        return tlv(0x06, out.toByteArray())
    }

    private fun time(d: Date): ByteArray {
        val f = SimpleDateFormat("yyMMddHHmmss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        return tlv(0x17, f.format(d).toByteArray())
    }

    fun create(): Pair<X509Certificate, PrivateKey> {
        val kp = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        val serial = ByteArray(16).also { SecureRandom().nextBytes(it) }
        serial[0] = (serial[0].toInt() and 0x7f).toByte()
        val name = seq(tlv(0x31, seq(oid(2, 5, 4, 3), tlv(0x0c, "mytify.local".toByteArray()))))
        val alg = seq(oid(1, 2, 840, 10045, 4, 3, 2))
        val now = System.currentTimeMillis()
        val tbs =
            seq(
                tlv(0xa0, tlv(0x02, byteArrayOf(2))),
                tlv(0x02, serial),
                alg,
                name,
                seq(time(Date(now - 86_400_000L)), time(Date(now + 20L * 365 * 86_400_000L))),
                name,
                kp.public.encoded,
            )
        val sig = Signature.getInstance("SHA256withECDSA").apply {
            initSign(kp.private)
            update(tbs)
        }.sign()
        val der = seq(tbs, alg, tlv(0x03, byteArrayOf(0) + sig))
        val cert = CertificateFactory.getInstance("X.509").generateCertificate(der.inputStream()) as X509Certificate
        return cert to kp.private
    }
}

/**
 * This phone shares its music with another phone, with the same protocol as Mytify on
 * the PC: a one-use QR carries the certificate pin, each paired phone gets its own
 * token (only its hash is kept), files go over TLS in the local network only.
 */
internal class PhoneShare(
    private val context: Context,
    private val store: ShareStore = EncryptedShareStore(context),
    private val allowLoopback: Boolean = false,
) {
    private val catalog = Catalog(context)
    private val lock = Any()
    private var identity: JSONObject = load()
    private var server: ServerSocket? = null
    private val stop = AtomicBoolean(true)
    private val clients = AtomicInteger(0)
    private var secret = ""
    private var expires = 0L
    private var host = ""
    private var qr: String? = null

    /** Last failures of the server threads (diagnostics and tests). */
    internal val failures = java.util.concurrent.CopyOnWriteArrayList<String>()

    private fun failed(e: Throwable) {
        if (failures.size > 20) failures.removeAt(0)
        failures.add("${e.javaClass.simpleName}: ${e.message}")
    }

    private fun now() = System.currentTimeMillis() / 1000

    private fun random(): String = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }

    private fun load(): JSONObject {
        store.load()?.let { return it }
        val (cert, key) = SelfSigned.create()
        val j =
            obj(
                "cert" to Base64.encodeToString(cert.encoded, Base64.NO_WRAP),
                "key" to Base64.encodeToString(key.encoded, Base64.NO_WRAP),
                "peers" to JSONArray(),
            )
        store.save(j)
        return j
    }

    private fun certBytes() = Base64.decode(identity.getString("cert"), Base64.NO_WRAP)

    fun fingerprint(): String = sha(certBytes())

    private fun name(): String =
        runCatching {
                android.provider.Settings.Global.getString(context.contentResolver, "device_name")
            }
            .getOrNull()
            ?.takeIf { it.isNotBlank() } ?: android.os.Build.MODEL ?: "Telefon"

    fun addresses(): List<String> =
        runCatching {
                NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }.flatMap { i ->
                    i.inetAddresses.toList().filterIsInstance<Inet4Address>().filter { it.isSiteLocalAddress }.map {
                        it.hostAddress ?: ""
                    }
                }
            }
            .getOrDefault(emptyList())
            .filter { it.isNotEmpty() }
            .distinct()
            .sorted()
            .ifEmpty { if (allowLoopback) listOf("127.0.0.1") else emptyList() }

    private fun link() =
        "mytify://pair?v=1&host=$host&port=${server?.localPort ?: 0}&fingerprint=${fingerprint()}&secret=$secret"

    private fun qrImage(text: String): String? =
        runCatching {
                val bitmap =
                    com.journeyapps.barcodescanner.BarcodeEncoder()
                        .encodeBitmap(text, com.google.zxing.BarcodeFormat.QR_CODE, 480, 480)
                val out = ByteArrayOutputStream()
                bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
                Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
            }
            .getOrNull()

    fun status(): JSONObject =
        synchronized(lock) {
            val live = server != null
            val valid = live && secret.isNotEmpty() && now() < expires
            val peers = identity.getJSONArray("peers")
            obj(
                "enabled" to live,
                "addresses" to JSONArray(addresses()),
                "port" to server?.localPort,
                "pairUri" to if (valid) link() else null,
                "qr" to if (valid) qr else null,
                "expires" to if (live) expires else null,
                "peers" to
                    JSONArray(
                        (0 until peers.length()).map {
                            val p = peers.getJSONObject(it)
                            obj("id" to p.getString("id"), "name" to p.getString("name"), "created" to p.getLong("created"))
                        }
                    ),
            )
        }

    fun command(v: JSONObject): JSONObject {
        when (v.optString("action", "status")) {
            "status" -> {}
            "start" -> start(v.text("host"))
            "renew" -> renew(v.text("host"))
            "stop" -> stop()
            "revoke" ->
                synchronized(lock) {
                    val peers = identity.getJSONArray("peers")
                    val kept = JSONArray()
                    for (i in 0 until peers.length()) {
                        val p = peers.getJSONObject(i)
                        if (p.getString("id") != v.optString("id")) kept.put(p)
                    }
                    identity.put("peers", kept)
                    store.save(identity)
                }
            else -> error("Nieznana operacja udostępniania")
        }
        return status()
    }

    private fun renew(h: String?) =
        synchronized(lock) {
            check(server != null) { "Włącz udostępnianie" }
            if (h != null) {
                require(h in addresses()) { "Nieprawidłowy adres" }
                host = h
            }
            secret = random()
            expires = now() + 120
            qr = qrImage(link())
        }

    fun start(h: String? = null, port: Int = 47480) {
        stop()
        val list = addresses()
        val chosen = h ?: list.firstOrNull() ?: error("Brak adresu w sieci lokalnej. Połącz telefon z Wi-Fi.")
        require(chosen in list) { "Wybierz adres tego telefonu" }
        val key =
            KeyFactory.getInstance("EC")
                .generatePrivate(PKCS8EncodedKeySpec(Base64.decode(identity.getString("key"), Base64.NO_WRAP)))
        val cert = CertificateFactory.getInstance("X.509").generateCertificate(certBytes().inputStream())
        val ks = KeyStore.getInstance("PKCS12").apply {
            load(null, null)
            setKeyEntry("share", key, CharArray(0), arrayOf(cert))
        }
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(ks, CharArray(0)) }
        val ssl = SSLContext.getInstance("TLS").apply { init(kmf.keyManagers, null, null) }
        val socket =
            runCatching { ssl.serverSocketFactory.createServerSocket(port, 8) }
                .getOrElse { ssl.serverSocketFactory.createServerSocket(0, 8) } as SSLServerSocket
        socket.soTimeout = 500
        synchronized(lock) {
            server = socket
            host = chosen
            stop.set(false)
        }
        renew(null)
        val flag = stop
        Thread({
                while (!flag.get()) {
                    val s =
                        try {
                            socket.accept()
                        } catch (_: SocketTimeoutException) {
                            continue
                        } catch (e: Exception) {
                            failed(e)
                            break
                        }
                    val a = s.inetAddress
                    val allowed =
                        a is Inet4Address && (a.isSiteLocalAddress || (allowLoopback && a.isLoopbackAddress))
                    if (!allowed) failed(IllegalStateException("refused ${a}"))
                    if (!allowed || clients.incrementAndGet() > 4) {
                        if (allowed) clients.decrementAndGet()
                        runCatching { s.close() }
                        continue
                    }
                    Thread({
                            try {
                                s.soTimeout = 15000
                                s.use { serve(it.getInputStream(), it.getOutputStream(), flag) }
                            } catch (e: Exception) {
                                failed(e)
                            } finally {
                                clients.decrementAndGet()
                            }
                        }, "mytify-share-client")
                        .start()
                }
                runCatching { socket.close() }
            }, "mytify-share")
            .start()
    }

    fun stop() =
        synchronized(lock) {
            stop.set(true)
            runCatching { server?.close() }
            server = null
            secret = ""
            qr = null
        }

    private fun authorized(token: String): Boolean {
        if (!transferId(token)) return false
        val h = sha(token.toByteArray()).toByteArray()
        synchronized(lock) {
            val peers = identity.getJSONArray("peers")
            return (0 until peers.length()).any {
                MessageDigest.isEqual(peers.getJSONObject(it).getString("tokenHash").toByteArray(), h)
            }
        }
    }

    private fun readLine(input: InputStream, limit: Int): String {
        val b = ByteArrayOutputStream()
        while (true) {
            val c = input.read()
            require(c >= 0) { "Niepełne HTTP" }
            b.write(c)
            require(b.size() <= limit) { "Żądanie za duże" }
            if (c == '\n'.code) break
        }
        return b.toString("UTF-8")
    }

    private fun respond(out: OutputStream, status: Int, body: ByteArray = ByteArray(0), length: Long? = null, extra: Map<String, String> = emptyMap()) {
        val h = StringBuilder("HTTP/1.1 $status OK\r\nContent-Length: ${length ?: body.size.toLong()}\r\nConnection: close\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n")
        extra.forEach { (k, v) -> h.append("$k: $v\r\n") }
        h.append("\r\n")
        out.write(h.toString().toByteArray())
        out.write(body)
        out.flush()
    }

    /** Tracks with a file on this phone (not on a NAS or server): the shared library. */
    fun manifest(): JSONObject {
        val tracks = JSONArray()
        catalog.readableDatabase
            .rawQuery(
                "SELECT t.id,t.raw,t.patch FROM tracks t WHERE EXISTS(SELECT 1 FROM locations l WHERE l.track=t.id AND l.available=1 AND (l.uri LIKE 'content:%' OR l.uri LIKE 'file:%')) ORDER BY t.added DESC",
                null,
            )
            .use { c ->
                while (c.moveToNext() && tracks.length() < 10000) {
                    val raw = JSONObject(c.getString(1))
                    val patch = JSONObject(c.getString(2))
                    patch.keys().forEach { raw.put(it, patch.get(it)) }
                    val size = raw.optLong("size")
                    if (size <= 0) continue
                    tracks.put(
                        obj(
                            "id" to c.getString(0),
                            "title" to raw.optString("title").take(512),
                            "artist" to raw.optString("artist").take(512),
                            "album" to raw.optString("album").take(512),
                            "albumArtist" to raw.optString("albumArtist").take(512),
                            "fileName" to raw.optString("fileName").substringAfterLast('/').take(256),
                            "format" to raw.optString("format").take(24),
                            "size" to size,
                            "durationMs" to raw.optLong("durationMs"),
                            "sampleRate" to raw.optInt("sampleRate"),
                            "bitDepth" to raw.optInt("bitDepth"),
                            "trackNumber" to raw.optInt("trackNumber"),
                            "discNumber" to raw.optInt("discNumber"),
                            "cover" to raw.optString("cover").takeIf { transferId(it) },
                            "available" to true,
                        )
                    )
                }
            }
        return obj("v" to 1, "identity" to fingerprint(), "name" to name(), "tracks" to tracks, "playlists" to JSONArray())
    }

    private fun localUri(id: String): Uri? =
        catalog.readableDatabase
            .rawQuery(
                "SELECT uri FROM locations WHERE track=? AND available=1 AND (uri LIKE 'content:%' OR uri LIKE 'file:%') LIMIT 1",
                arrayOf(id),
            )
            .use { if (it.moveToFirst()) Uri.parse(it.getString(0)) else null }

    internal fun serve(rawInput: InputStream, out: OutputStream, stopped: AtomicBoolean) {
        val input = BufferedInputStream(rawInput)
        val first = readLine(input, 4096).trimEnd()
        val parts = first.split(' ')
        require(parts.size == 3 && parts[2] == "HTTP/1.1") { "Nieprawidłowe HTTP" }
        val (method, path) = parts[0] to parts[1]
        val headers = HashMap<String, String>()
        var total = first.length
        while (true) {
            val line = readLine(input, 16384)
            total += line.length
            require(total <= 16384) { "Nagłówki za duże" }
            if (line == "\r\n") break
            val i = line.indexOf(':')
            require(i > 0) { "Nagłówek" }
            require(headers.put(line.substring(0, i).lowercase(), line.substring(i + 1).trim()) == null) { "Powtórzony nagłówek" }
        }
        if (stopped.get()) return
        val length = headers["content-length"]?.toInt() ?: 0
        require(length in 0..4096 && "transfer-encoding" !in headers) { "Nieprawidłowe żądanie" }
        val body = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(body, read, length - read)
            require(n > 0)
            read += n
        }
        if ("origin" in headers || "referer" in headers) return respond(out, 403)
        if (method == "POST" && path == "/pair") {
            val v = JSONObject(String(body, Charsets.UTF_8))
            val result =
                synchronized(lock) {
                    val valid =
                        secret.isNotEmpty() && now() < expires &&
                            MessageDigest.isEqual(secret.toByteArray(), v.optString("secret").toByteArray())
                    if (!valid) null
                    else {
                        val peers = identity.getJSONArray("peers")
                        check(peers.length() < 32) { "Za dużo sparowanych urządzeń" }
                        val token = random()
                        val id = random()
                        peers.put(
                            obj(
                                "id" to id,
                                "name" to v.optString("name", "Telefon").take(80),
                                "tokenHash" to sha(token.toByteArray()),
                                "created" to now(),
                            )
                        )
                        store.save(identity)
                        // One use: the code is gone after this phone pairs.
                        secret = ""
                        qr = null
                        obj("identity" to fingerprint(), "token" to token, "id" to id, "name" to name())
                    }
                }
            return if (result == null) respond(out, 403) else respond(out, 200, result.toString().toByteArray())
        }
        val token = headers["authorization"]?.removePrefix("Bearer ") ?: ""
        if (!authorized(token)) return respond(out, 401)
        if (method == "GET" && path == "/manifest") return respond(out, 200, manifest().toString().toByteArray())
        if (method == "GET" && path.startsWith("/cover/")) {
            val key = path.removePrefix("/cover/")
            val f = if (transferId(key)) catalog.coverFile(key) else null
            if (f == null || f.length() > 8 * 1024 * 1024) return respond(out, 404)
            return respond(out, 200, f.readBytes())
        }
        if (method != "GET" || !path.startsWith("/file/")) return respond(out, 404)
        val key = path.removePrefix("/file/")
        val uri = (if (transferId(key)) localUri(key) else null) ?: return respond(out, 404)
        val fd = context.contentResolver.openAssetFileDescriptor(uri, "r") ?: return respond(out, 404)
        fd.use { afd ->
            afd.createInputStream().use { file ->
                val size =
                    if (afd.length >= 0) afd.length
                    else afd.parcelFileDescriptor.statSize
                require(size > 0) { "Nieznany rozmiar pliku" }
                val range = headers["range"]
                val offset =
                    if (range == null) 0L
                    else range.removePrefix("bytes=").removeSuffix("-").toLongOrNull()?.takeIf { it in 0 until size }
                        ?: return respond(out, 416)
                var skipped = 0L
                while (skipped < offset) {
                    val n = file.skip(offset - skipped)
                    require(n > 0) { "Nie można przewinąć pliku" }
                    skipped += n
                }
                respond(
                    out,
                    if (range == null) 200 else 206,
                    length = size - offset,
                    extra = if (range == null) emptyMap() else mapOf("Content-Range" to "bytes $offset-${size - 1}/$size"),
                )
                val buf = ByteArray(65536)
                var left = size - offset
                while (left > 0) {
                    check(!stopped.get() && authorized(token)) { "Udostępnianie zatrzymane" }
                    val n = file.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
                    check(n > 0) { "Plik zmienił się podczas wysyłania" }
                    out.write(buf, 0, n)
                    left -= n
                }
                out.flush()
            }
        }
    }

    companion object {
        @Volatile private var shared: PhoneShare? = null

        fun get(context: Context) =
            shared ?: synchronized(this) { shared ?: PhoneShare(context.applicationContext).also { shared = it } }
    }
}
