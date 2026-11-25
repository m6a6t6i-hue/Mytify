package pl.mytify.mytify

import android.content.Context
import android.media.MediaDataSource
import android.net.Uri
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.RandomAccessFile
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException
import okhttp3.Credentials
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory

/** WebDAV settings. The password is kept apart, in [Secrets]. */
data class DavSettings(val name: String, val url: String, val folder: String, val user: String) {
    fun json(): JSONObject =
        obj("protocol" to "webdav", "name" to name, "url" to url, "folder" to folder, "user" to user)

    /** Folder URL: server address, chosen folder and [extra], with a trailing slash. */
    fun root(extra: String = ""): HttpUrl {
        val base = url.toHttpUrlOrNull()!!
        val segments =
            base.pathSegments.filter { it.isNotEmpty() } + SmbSettings.segments(folder) + SmbSettings.segments(extra)
        val b = base.newBuilder().encodedPath("/")
        segments.forEach { b.addPathSegment(it) }
        if (segments.isNotEmpty()) b.addPathSegment("")
        return b.build()
    }

    val address: String
        get() = Uri.decode(root().toString())

    companion object {
        /** HTTPS only, no credentials inside the address. Same rules as on the PC. */
        fun parse(j: JSONObject): DavSettings {
            val raw = j.optString("url").trim()
            require(raw.isNotEmpty()) { "Podaj adres serwera WebDAV." }
            val withScheme = if ("://" in raw) raw else "https://$raw"
            val u = withScheme.toHttpUrlOrNull() ?: throw IllegalArgumentException("Adres serwera jest nieprawidłowy.")
            require(u.scheme == "https") { "WebDAV wymaga połączenia HTTPS (adres zaczyna się od https://)." }
            require(u.username.isEmpty() && u.password.isEmpty()) { "Nie wpisuj loginu ani hasła w adresie. Użyj pól poniżej." }
            val clean = u.newBuilder().query(null).fragment(null).build().let {
                if (it.encodedPath.endsWith("/")) it else it.newBuilder().addPathSegment("").build()
            }
            val folder = SmbSettings.segments(j.optString("folder")).joinToString("/")
            val user = j.optString("user").trim()
            require(user.length <= 256) { "Nazwa użytkownika jest nieprawidłowa." }
            val name =
                j.optString("name").trim().take(80).ifEmpty {
                    folder.substringAfterLast('/').ifEmpty {
                        clean.pathSegments.lastOrNull { it.isNotEmpty() } ?: clean.host
                    }
                }
            return DavSettings(name, clean.toString(), folder, user)
        }
    }
}

object WebDav {
    data class Entry(val href: String, val name: String, val dir: Boolean, val size: Long, val version: String)

    val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            // Never from HTTPS to HTTP. OkHttp drops Authorization on a redirect to another host,
            // and [call] refuses such answers anyway.
            .followSslRedirects(false)
            .build()
    }

    fun friendly(e: Throwable): SourceException {
        if (e is SourceException) return e
        var c: Throwable? = e
        while (c != null) {
            when (c) {
                is SSLPeerUnverifiedException,
                is SSLHandshakeException,
                is java.security.cert.CertificateException ->
                    return SourceException(
                        "Certyfikat serwera nie jest zaufany. Mytify nie łączy się z serwerem bez ważnego certyfikatu HTTPS.",
                        e,
                    )
                is UnknownHostException -> return SourceException("Nie znaleziono serwera. Sprawdź adres.", e)
                is SocketTimeoutException -> return SourceException("Serwer nie odpowiada.", e)
                is ConnectException -> return SourceException("Serwer jest nieosiągalny.", e)
            }
            c = c.cause
        }
        return SourceException("Połączenie z serwerem nie powiodło się.", e)
    }

    private fun status(code: Int) =
        SourceException(
            when (code) {
                401 -> "Nieprawidłowy użytkownik lub hasło."
                403 -> "Brak dostępu do tego folderu."
                404 -> "Folder lub plik nie istnieje."
                405, 501 -> "Pod tym adresem nie ma serwera WebDAV."
                in 300..399 -> "Serwer przekierowuje na inny adres. Wpisz docelowy adres serwera."
                in 500..599 -> "Błąd serwera. Spróbuj później."
                else -> "Serwer odrzucił żądanie (HTTP $code)."
            }
        )

    fun auth(s: DavSettings, password: String): String? =
        if (s.user.isEmpty()) null else Credentials.basic(s.user, password, Charsets.UTF_8)

    /** Sends a request to the source's own server only. */
    fun call(s: DavSettings, password: String, build: Request.Builder.() -> Unit): Response {
        val builder = Request.Builder().header("User-Agent", "Mytify")
        auth(s, password)?.let { builder.header("Authorization", it) }
        val request = builder.apply(build).build()
        val origin = s.url.toHttpUrlOrNull()!!
        require(request.url.host == origin.host && request.url.port == origin.port) { "Serwer wskazał plik na innym serwerze." }
        val response =
            try {
                client.newCall(request).execute()
            } catch (e: IOException) {
                throw friendly(e)
            }
        if (response.request.url.host != origin.host) {
            response.close()
            throw SourceException("Serwer przekierowuje na inny adres. Wpisz docelowy adres serwera.")
        }
        return response
    }

    /** One folder level (PROPFIND Depth 1). */
    fun list(s: DavSettings, password: String, folder: HttpUrl): List<Entry> {
        val body =
            "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getcontentlength/><d:getetag/><d:getlastmodified/></d:prop></d:propfind>"
        call(s, password) {
            url(folder)
            header("Depth", "1")
            method("PROPFIND", body.toRequestBody("application/xml; charset=utf-8".toMediaType()))
        }.use { r ->
            if (r.code != 207) throw status(r.code)
            return parse(r.body!!.string(), folder)
        }
    }

    fun parse(xml: String, folder: HttpUrl): List<Entry> {
        val p = XmlPullParserFactory.newInstance().apply { isNamespaceAware = true }.newPullParser()
        p.setInput(xml.reader())
        val out = mutableListOf<Entry>()
        var href: String? = null
        var dir = false
        var size = 0L
        var etag = ""
        var modified = ""
        var ok = true
        var text = StringBuilder()
        while (true) {
            when (p.next()) {
                XmlPullParser.END_DOCUMENT -> break
                XmlPullParser.START_TAG ->
                    if (p.namespace == "DAV:") {
                        text = StringBuilder()
                        when (p.name) {
                            "response" -> {
                                href = null; dir = false; size = 0; etag = ""; modified = ""; ok = true
                            }
                            "collection" -> if (ok) dir = true
                        }
                    }
                XmlPullParser.TEXT -> text.append(p.text)
                XmlPullParser.END_TAG ->
                    if (p.namespace == "DAV:") {
                        val t = text.toString().trim()
                        when (p.name) {
                            "href" -> href = t
                            "status" -> ok = " 200" in t
                            "getcontentlength" -> if (ok) size = t.toLongOrNull() ?: 0
                            "getetag" -> if (ok) etag = t
                            "getlastmodified" -> if (ok) modified = t
                            "response" -> {
                                val u = href?.let { folder.resolve(it) }
                                if (
                                    u != null &&
                                        u.host == folder.host &&
                                        u.port == folder.port &&
                                        u.encodedPath.startsWith(folder.encodedPath) &&
                                        u.encodedPath.trimEnd('/') != folder.encodedPath.trimEnd('/')
                                ) {
                                    val name = u.pathSegments.lastOrNull { it.isNotEmpty() } ?: ""
                                    out.add(Entry(u.encodedPath, name, dir, size, etag.ifEmpty { modified }))
                                }
                            }
                        }
                    }
            }
        }
        return out
    }

    /** smb-like location: dav://<source id>/<server path, percent-encoded as listed>. */
    fun uri(sourceId: String, href: String): Uri = Uri.parse("dav://$sourceId$href")

    fun https(s: DavSettings, location: Uri): HttpUrl {
        val origin = s.url.toHttpUrlOrNull()!!
        return origin.newBuilder().encodedPath(location.encodedPath ?: "/").build()
    }

    /** Range GET. Returns the response and whether the server honoured the range. */
    fun read(s: DavSettings, password: String, url: HttpUrl, start: Long, length: Long): Pair<Response, Boolean> {
        val r = call(s, password) {
            url(url)
            header("Range", "bytes=$start-${start + maxOf(1, length) - 1}")
        }
        if (r.code != 206 && r.code != 200) {
            r.close()
            throw status(r.code)
        }
        return r to (r.code == 206)
    }

    fun stream(s: DavSettings, password: String, url: HttpUrl, offset: Long): InputStream {
        val (r, ranged) = read(s, password, url, offset, Long.MAX_VALUE / 4)
        val input = r.body!!.byteStream()
        if (!ranged && offset > 0) input.skip(offset)
        return input
    }
}

/**
 * Random access for MediaMetadataRetriever over HTTP ranges. Without Range support the file
 * is downloaded once to the cache and read from there (slower, but correct).
 */
class DavMediaDataSource(
    private val s: DavSettings,
    private val password: String,
    private val url: HttpUrl,
    private val length: Long,
    private val cache: File,
) : MediaDataSource() {
    private var block = ByteArray(0)
    private var blockStart = 0L
    private var whole: RandomAccessFile? = null

    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (position >= length) return -1
        whole?.let {
            it.seek(position)
            return it.read(buffer, offset, size)
        }
        if (position < blockStart || position >= blockStart + block.size) {
            val want = minOf(256L * 1024, length - position)
            val (r, ranged) = WebDav.read(s, password, url, position, want)
            r.use {
                if (!ranged) {
                    cache.parentFile?.mkdirs()
                    cache.outputStream().use { out -> it.body!!.byteStream().copyTo(out) }
                    check(cache.length() == length) { "Plik na serwerze ma inny rozmiar niż przy skanowaniu." }
                    whole = RandomAccessFile(cache, "r")
                    return readAt(position, buffer, offset, size)
                }
                block = it.body!!.bytes()
                blockStart = position
            }
        }
        val n = minOf(size, (blockStart + block.size - position).toInt())
        System.arraycopy(block, (position - blockStart).toInt(), buffer, offset, n)
        return n
    }

    override fun getSize() = length

    override fun close() {
        whole?.close()
        whole = null
        cache.delete()
    }
}
