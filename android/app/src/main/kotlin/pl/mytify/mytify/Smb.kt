package pl.mytify.mytify

import android.content.Context
import android.media.MediaDataSource
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSourceException
import androidx.media3.datasource.DataSpec
import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.msfscc.FileAttributes
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2Dialect
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.mssmb2.SMBApiException
import com.hierynomus.security.bc.BCSecurityProvider
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.connection.Connection
import com.hierynomus.smbj.session.Session
import com.hierynomus.smbj.share.DiskShare
import com.hierynomus.smbj.share.File as SmbFile
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.EnumSet
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import org.json.JSONObject

/** Settings of an SMB 2/3 share. The password is kept apart, in [Secrets]. */
data class SmbSettings(
    val name: String,
    val host: String,
    val share: String,
    val folder: String,
    val user: String,
    val domain: String,
) {
    fun json(): JSONObject =
        obj(
            "protocol" to "smb",
            "name" to name,
            "host" to host,
            "share" to share,
            "folder" to folder,
            "user" to user,
            "domain" to domain,
        )

    /** Address shown to the user, never with credentials. */
    val address: String
        get() = "\\\\$host\\$share" + folder.split('/').filter { it.isNotEmpty() }.joinToString("") { "\\$it" }

    /** Path inside the share in smbj form. */
    fun inside(relative: String = ""): String =
        (folder.split('/') + relative.split('/')).filter { it.isNotEmpty() }.joinToString("\\")

    companion object {
        private fun bad(c: Char) = c.isISOControl() || c in "\\/:*?\"<>|"

        fun segments(path: String): List<String> =
            path.split('/', '\\').map { it.trim() }.filter { it.isNotEmpty() && it != "." }.onEach {
                require(it != ".." && it.none(::bad)) { "Ścieżka folderu jest nieprawidłowa." }
            }

        /** Same rules as the PC version: pasted "\\nas\" or "smb://nas" are fine. */
        fun parse(j: JSONObject): SmbSettings {
            val host =
                j.optString("host").trim().removePrefix("smb://").trimStart('\\').trimEnd('/', '\\')
            require(host.isNotEmpty()) { "Podaj adres serwera." }
            require(host.length <= 253 && host.all { it.isLetterOrDigit() && it.code < 128 || it in ".-_" }) {
                "Adres serwera może zawierać tylko litery, cyfry, kropki i myślniki."
            }
            val share = j.optString("share").trim().trim('/', '\\')
            require(share.isNotEmpty()) { "Podaj nazwę udziału." }
            require(share.length <= 80 && share.none(::bad)) { "Nazwa udziału zawiera niedozwolone znaki." }
            val folder = segments(j.optString("folder")).joinToString("/")
            val user = j.optString("user").trim()
            val domain = j.optString("domain").trim()
            require(user.length <= 256 && domain.length <= 256) { "Nazwa użytkownika jest nieprawidłowa." }
            val name =
                j.optString("name").trim().take(80).ifEmpty {
                    folder.substringAfterLast('/').ifEmpty { share }
                }
            return SmbSettings(name, host, share, folder, user, domain)
        }
    }
}

/** Readable message for a failed SMB operation. No class names or status codes. */
class SourceException(message: String, cause: Throwable? = null) : IOException(message, cause)

object Smb {
    private val client by lazy {
        SMBClient(
            SmbConfig.builder()
                // MD4 and AES-CMAC/CCM/GCM are not in the Android JCE.
                .withSecurityProvider(BCSecurityProvider())
                .withDialects(
                    SMB2Dialect.SMB_3_1_1,
                    SMB2Dialect.SMB_3_0_2,
                    SMB2Dialect.SMB_3_0,
                    SMB2Dialect.SMB_2_1,
                    SMB2Dialect.SMB_2_0_2,
                )
                .withTimeout(15, TimeUnit.SECONDS)
                .withSoTimeout(20, TimeUnit.SECONDS)
                .build()
        )
    }

    private class Open(val connection: Connection, val session: Session, val share: DiskShare) {
        val alive
            get() = connection.isConnected && share.isConnected
    }

    private val open = ConcurrentHashMap<String, Open>()
    private val locks = ConcurrentHashMap<String, Any>()

    fun friendly(e: Throwable): SourceException {
        if (e is SourceException) return e
        var c: Throwable? = e
        while (c != null) {
            when (c) {
                is SMBApiException ->
                    return SourceException(
                        when (c.status.name) {
                            "STATUS_LOGON_FAILURE",
                            "STATUS_WRONG_PASSWORD",
                            "STATUS_NO_SUCH_USER" -> "Nieprawidłowy użytkownik lub hasło."
                            "STATUS_ACCOUNT_DISABLED",
                            "STATUS_ACCOUNT_LOCKED_OUT",
                            "STATUS_PASSWORD_EXPIRED",
                            "STATUS_ACCOUNT_EXPIRED" -> "Konto na serwerze jest zablokowane albo wygasło."
                            "STATUS_BAD_NETWORK_NAME" -> "Serwer nie ma udziału o tej nazwie."
                            "STATUS_ACCESS_DENIED" -> "Brak dostępu do udziału dla tego konta."
                            "STATUS_OBJECT_NAME_NOT_FOUND",
                            "STATUS_OBJECT_PATH_NOT_FOUND" -> "Folder lub plik nie istnieje."
                            "STATUS_NETWORK_NAME_DELETED",
                            "STATUS_USER_SESSION_DELETED",
                            "STATUS_NETWORK_SESSION_EXPIRED" -> "Połączenie z serwerem zostało przerwane."
                            else -> "Serwer odrzucił operację."
                        },
                        e,
                    )
                is UnknownHostException ->
                    return SourceException("Nie znaleziono serwera. Sprawdź adres i sieć Wi-Fi.", e)
                is SocketTimeoutException -> return SourceException("Serwer nie odpowiada.", e)
                is ConnectException,
                is NoRouteToHostException -> return SourceException("Serwer jest nieosiągalny.", e)
            }
            c = c.cause
        }
        return SourceException("Nie można połączyć z udziałem.", e)
    }

    private fun connect(s: SmbSettings, password: String): Open {
        val connection = client.connect(s.host)
        try {
            val auth =
                if (s.user.isEmpty()) AuthenticationContext.guest()
                else AuthenticationContext(s.user, password.toCharArray(), s.domain.ifEmpty { null })
            val session = connection.authenticate(auth)
            val share = session.connectShare(s.share) as? DiskShare
            if (share == null) {
                session.close()
                throw SourceException("Ten udział nie jest folderem z plikami.")
            }
            return Open(connection, session, share)
        } catch (e: Exception) {
            runCatching { connection.close() }
            throw e
        }
    }

    fun close(key: String) {
        open.remove(key)?.let { o ->
            runCatching { o.share.close() }
            runCatching { o.session.close() }
            runCatching { o.connection.close() }
        }
    }

    /**
     * Runs [block] on a live share session. A dropped session (sleep, Wi-Fi change) is
     * opened again once before giving up.
     */
    fun <T> with(key: String, s: SmbSettings, password: String, block: (DiskShare) -> T): T {
        for (attempt in 0..1) {
            val share =
                try {
                    synchronized(locks.getOrPut(key) { Any() }) {
                        open[key]?.takeIf { it.alive }?.share
                            ?: run {
                                close(key)
                                connect(s, password).also { open[key] = it }.share
                            }
                    }
                } catch (e: Exception) {
                    throw friendly(e)
                }
            try {
                return block(share)
            } catch (e: SMBApiException) {
                val name = e.status.name
                val session = name.contains("SESSION") || name.contains("NETWORK_NAME_DELETED")
                if (attempt == 0 && session) {
                    close(key)
                    continue
                }
                throw friendly(e)
            } catch (e: SourceException) {
                throw e
            } catch (e: Exception) {
                if (attempt == 0 && !share.isConnected) {
                    close(key)
                    continue
                }
                throw friendly(e)
            }
        }
        throw SourceException("Połączenie z serwerem zostało przerwane.")
    }

    data class Entry(val path: String, val name: String, val size: Long, val modified: Long)

    fun folders(share: DiskShare, s: SmbSettings, relative: String): List<String> =
        share
            .list(s.inside(relative).ifEmpty { "" })
            .filter {
                it.fileName !in setOf(".", "..") &&
                    !it.fileName.startsWith('.') &&
                    !it.fileName.startsWith('#') &&
                    it.fileName != "@eaDir" &&
                    it.fileAttributes and FileAttributes.FILE_ATTRIBUTE_DIRECTORY.value != 0L
            }
            .map { it.fileName }
            .sortedBy { it.lowercase() }

    /** Recursive walk below the chosen folder. Paths are relative to the share. */
    fun walk(
        share: DiskShare,
        s: SmbSettings,
        audio: (String) -> Boolean,
        cancelled: () -> Boolean,
    ): List<Entry> {
        val out = mutableListOf<Entry>()
        val todo = ArrayDeque<String>().apply { add(s.inside()) }
        var visited = 0
        while (todo.isNotEmpty()) {
            if (cancelled()) throw java.util.concurrent.CancellationException()
            val dir = todo.removeFirst()
            require(++visited + out.size <= 200000) { "Wybierz mniejszy folder" }
            for (f in share.list(dir)) {
                val name = f.fileName
                if (name == "." || name == ".." || name.startsWith('.') || name == "@eaDir" || name.startsWith('#')) continue
                val path = if (dir.isEmpty()) name else "$dir\\$name"
                if (f.fileAttributes and FileAttributes.FILE_ATTRIBUTE_DIRECTORY.value != 0L) todo.add(path)
                else if (audio(name))
                    out.add(Entry(path.replace('\\', '/'), name, f.endOfFile, f.lastWriteTime.toEpochMillis()))
            }
        }
        return out.sortedBy { it.path }
    }

    fun openFile(share: DiskShare, path: String): SmbFile =
        share.openFile(
            path.replace('/', '\\'),
            EnumSet.of(AccessMask.GENERIC_READ),
            null,
            SMB2ShareAccess.ALL,
            SMB2CreateDisposition.FILE_OPEN,
            null,
        )

    /** smb://<source id>/<path inside the share>, used as the track location. */
    fun uri(sourceId: String, path: String): Uri =
        Uri.Builder()
            .scheme("smb")
            .authority(sourceId)
            .apply { path.split('/').filter { it.isNotEmpty() }.forEach { appendPath(it) } }
            .build()
}

/** Random access for MediaMetadataRetriever (tags, duration, embedded cover). */
class SmbMediaDataSource(private val file: SmbFile, private val length: Long) : MediaDataSource() {
    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (position >= length) return -1
        val n = minOf(size.toLong(), length - position).toInt()
        return file.read(buffer, position, offset, n).let { if (it <= 0) -1 else it }
    }

    override fun getSize() = length

    override fun close() {}
}

/**
 * Playback straight from the share. Seeking reads only the needed part of the file;
 * a small read-ahead buffer keeps round trips low on Wi-Fi.
 */
@UnstableApi
class SmbDataSource(private val context: Context) : BaseDataSource(true) {
    private var file: SmbFile? = null
    private var uri: Uri? = null
    private var position = 0L
    private var remaining = 0L
    private val buffer = ByteArray(512 * 1024)
    private var bufferStart = 0L
    private var bufferLength = 0
    private var opened = false

    override fun open(dataSpec: DataSpec): Long {
        uri = dataSpec.uri
        transferInitializing(dataSpec)
        val (f, size) =
            try {
                NetworkSources.open(context, dataSpec.uri)
            } catch (e: IOException) {
                throw DataSourceException(e, PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED)
            }
        file = f
        if (dataSpec.position > size) {
            throw DataSourceException(PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE)
        }
        position = dataSpec.position
        remaining = if (dataSpec.length != C.LENGTH_UNSET.toLong()) minOf(dataSpec.length, size - position) else size - position
        bufferLength = 0
        opened = true
        transferStarted(dataSpec)
        return remaining
    }

    override fun read(target: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (remaining == 0L) return C.RESULT_END_OF_INPUT
        if (position < bufferStart || position >= bufferStart + bufferLength) {
            val want = minOf(buffer.size.toLong(), remaining).toInt()
            val n =
                try {
                    file!!.read(buffer, position, 0, want)
                } catch (e: Exception) {
                    throw DataSourceException(Smb.friendly(e), PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED)
                }
            if (n <= 0) return C.RESULT_END_OF_INPUT
            bufferStart = position
            bufferLength = n
        }
        val available = (bufferStart + bufferLength - position).toInt()
        val n = minOf(length, available, minOf(remaining, Int.MAX_VALUE.toLong()).toInt())
        System.arraycopy(buffer, (position - bufferStart).toInt(), target, offset, n)
        position += n
        remaining -= n
        bytesTransferred(n)
        return n
    }

    override fun getUri(): Uri? = uri

    override fun close() {
        runCatching { file?.close() }
        file = null
        bufferLength = 0
        if (opened) {
            opened = false
            transferEnded()
        }
    }
}

/** Hands smb:// locations to [SmbDataSource], everything else to the stock Media3 sources. */
@UnstableApi
class RoutingDataSource(private val context: Context) : androidx.media3.datasource.DataSource {
    private val fallback = androidx.media3.datasource.DefaultDataSource(context, true)
    private val smb = SmbDataSource(context)
    private var current: androidx.media3.datasource.DataSource? = null

    private val listeners = mutableListOf<androidx.media3.datasource.TransferListener>()

    override fun addTransferListener(listener: androidx.media3.datasource.TransferListener) {
        listeners.add(listener)
        fallback.addTransferListener(listener)
        smb.addTransferListener(listener)
    }

    override fun open(dataSpec: DataSpec): Long {
        if (dataSpec.uri.scheme == "dav") {
            // WebDAV: plain HTTPS with ranges; the login header is added here, never stored in the URI.
            val id = dataSpec.uri.authority ?: throw IOException("Nieprawidłowy adres pliku.")
            val s = NetworkSources.dav(context, id)
            val headers = WebDav.auth(s, Secrets.load(context, id) ?: "")?.let { mapOf("Authorization" to it) } ?: emptyMap()
            val http =
                androidx.media3.datasource.okhttp.OkHttpDataSource.Factory(WebDav.client)
                    .setDefaultRequestProperties(headers)
                    .createDataSource()
            listeners.forEach { http.addTransferListener(it) }
            current = http
            return http.open(dataSpec.buildUpon().setUri(Uri.parse(WebDav.https(s, dataSpec.uri).toString())).build())
        }
        val source = if (dataSpec.uri.scheme == "smb") smb else fallback
        current = source
        return source.open(dataSpec)
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
        current?.read(buffer, offset, length) ?: C.RESULT_END_OF_INPUT

    override fun getUri(): Uri? = current?.uri

    override fun getResponseHeaders(): Map<String, List<String>> = current?.responseHeaders ?: emptyMap()

    override fun close() {
        try {
            current?.close()
        } finally {
            current = null
        }
    }

    class Factory(private val context: Context) : androidx.media3.datasource.DataSource.Factory {
        override fun createDataSource() = RoutingDataSource(context)
    }
}
