package pl.mytify.mytify

import android.content.Context
import android.net.Uri
import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import java.util.concurrent.TimeUnit
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject

/**
 * Internet radio: the Radio Browser directory (server list, fallback, click counting),
 * favourites and recent stations kept on the phone, and playlist files (.pls/.m3u) resolved
 * to the stream. Media3 plays the stream itself: MP3, AAC, HE-AAC, OGG and HLS.
 */
object Radio {
    const val USER_AGENT = "Mytify/0.22 (github.com/m6a6t6i-hue/Mytify)"
    private val FALLBACK =
        listOf("de1.api.radio-browser.info", "de2.api.radio-browser.info", "fi1.api.radio-browser.info", "nl1.api.radio-browser.info")

    data class Station(
        val id: String,
        val name: String,
        val url: String,
        val logo: String = "",
        val tags: List<String> = emptyList(),
        val country: String = "",
        val codec: String = "",
        val bitrate: Int = 0,
        val hls: Boolean = false,
    ) {
        fun json(): JSONObject =
            JSONObject()
                .put("id", id)
                .put("name", name)
                .put("url", url)
                .put("logo", logo)
                .put("tags", JSONArray(tags))
                .put("country", country)
                .put("codec", codec)
                .put("bitrate", bitrate)
                .put("hls", hls)

        companion object {
            fun from(o: JSONObject): Station? {
                val id = o.optString("id")
                val url = o.optString("url")
                if (!id.startsWith("radio:") || id.length > 100 || !http(url)) return null
                return Station(
                    id = id,
                    name = o.optString("name").take(300),
                    url = url,
                    logo = o.optString("logo").takeIf { http(it) } ?: "",
                    tags = o.optJSONArray("tags")?.strings().orEmpty(),
                    country = o.optString("country"),
                    codec = o.optString("codec"),
                    bitrate = o.optInt("bitrate"),
                    hls = o.optBoolean("hls"),
                )
            }

            /** A row of the directory. */
            fun directory(o: JSONObject): Station? {
                val uuid = o.optString("stationuuid").trim()
                if (uuid.isEmpty() || uuid.length > 64) return null
                val url = listOf(o.optString("url_resolved"), o.optString("url")).map { it.trim() }.firstOrNull { http(it) } ?: return null
                val logo = o.optString("favicon").trim()
                return Station(
                    id = "radio:$uuid",
                    name = o.optString("name").trim(),
                    url = url,
                    logo = if (http(logo)) logo else "",
                    tags = o.optString("tags").split(',').map { it.trim().lowercase() }.filter { it.isNotEmpty() }.take(6),
                    country = o.optString("countrycode"),
                    codec = o.optString("codec"),
                    bitrate = o.optInt("bitrate"),
                    hls = o.optInt("hls") == 1,
                )
            }
        }
    }

    fun http(s: String) = s.startsWith("http://") || s.startsWith("https://")

    val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(12, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .addInterceptor { chain -> chain.proceed(chain.request().newBuilder().header("User-Agent", USER_AGENT).build()) }
            .build()
    }

    @Volatile private var servers: List<String> = emptyList()

    private fun servers(): List<String> {
        servers.takeIf { it.isNotEmpty() }?.let { return it }
        val list =
            runCatching {
                    client.newCall(Request.Builder().url("https://all.api.radio-browser.info/json/servers").build()).execute().use { r ->
                        val a = JSONArray(r.body?.string() ?: "[]")
                        (0 until a.length()).mapNotNull { a.optJSONObject(it)?.optString("name") }.filter { it.endsWith(".radio-browser.info") }
                    }
                }
                .getOrDefault(emptyList())
                .distinct()
                .ifEmpty { FALLBACK }
                .shuffled()
        servers = list
        return list
    }

    private fun get(path: String): String {
        var last: Exception = java.io.IOException("Katalog stacji jest niedostępny.")
        for (server in servers()) {
            try {
                client.newCall(Request.Builder().url("https://$server$path").build()).execute().use { r ->
                    if (!r.isSuccessful) throw java.io.IOException("HTTP ${r.code}")
                    val body = r.body?.string() ?: ""
                    servers = listOf(server) + servers.filter { it != server }
                    return body
                }
            } catch (e: Exception) {
                last = e
            }
        }
        throw java.io.IOException(Lang.t("Katalog stacji radiowych nie odpowiada. Sprawdź internet") + ": ${last.message}")
    }

    fun search(name: String? = null, tag: String? = null, country: String? = null, order: String? = null, limit: Int = 40, offset: Int = 0): List<Station> {
        val u = "https://x/json/stations/search".toHttpUrlOrNull()!!.newBuilder()
        name?.trim()?.takeIf { it.isNotEmpty() }?.let { u.addQueryParameter("name", it.take(100)) }
        tag?.trim()?.takeIf { it.isNotEmpty() }?.let { u.addQueryParameter("tag", it.take(100)) }
        country?.takeIf { it.length == 2 && it.all { c -> c.isLetter() } }?.let { u.addQueryParameter("countrycode", it.uppercase()) }
        if (order == "name") u.addQueryParameter("order", "name")
        else u.addQueryParameter("order", "clickcount").addQueryParameter("reverse", "true")
        u.addQueryParameter("hidebroken", "true")
            .addQueryParameter("limit", limit.coerceIn(1, 100).toString())
            .addQueryParameter("offset", offset.coerceIn(0, 10000).toString())
        val built = u.build()
        val a = JSONArray(get(built.encodedPath + "?" + built.encodedQuery))
        return (0 until a.length()).mapNotNull { a.optJSONObject(it)?.let(Station::directory) }
    }

    /** Counts the listen in the directory, as it asks clients to, and returns the current address. */
    fun click(id: String): String? {
        val uuid = id.removePrefix("radio:")
        if (uuid.isEmpty() || uuid.length > 64 || !uuid.all { it.isLetterOrDigit() || it == '-' }) return null
        return runCatching { JSONObject(get("/json/url/$uuid")).optString("url").takeIf { http(it) } }.getOrNull()
    }

    fun parsePlaylist(text: String, base: String): String? {
        if (text.contains("#EXT-X-")) return "hls"
        val baseUrl = base.toHttpUrlOrNull()
        fun absolute(s: String): String? {
            val v = s.trim().trim('"')
            val u = baseUrl?.resolve(v) ?: v.toHttpUrlOrNull()
            return u?.toString()?.takeIf { http(it) }
        }
        text.lines().forEach { line ->
            val i = line.indexOf('=')
            if (i > 0 && line.substring(0, i).trim().lowercase().startsWith("file")) absolute(line.substring(i + 1))?.let { return it }
        }
        val lower = text.lowercase()
        for (tag in listOf("href=\"", "<location>")) {
            val i = lower.indexOf(tag)
            if (i >= 0) {
                val rest = text.substring(i + tag.length)
                val end = rest.indexOfAny(charArrayOf('"', '<')).let { if (it < 0) rest.length else it }
                absolute(rest.substring(0, end))?.let { return it }
            }
        }
        return text.lines().map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") && !it.startsWith("[") && !it.startsWith("<") }
            .firstNotNullOfOrNull { absolute(it) }
    }

    private fun playlistPath(url: String): Boolean {
        val p = url.substringBefore('?').substringBefore('#').lowercase()
        return listOf(".pls", ".m3u", ".asx", ".xspf").any { p.endsWith(it) }
    }

    /** Address Media3 can play: playlists are opened here, HLS stays HLS. Network thread only. */
    fun resolve(url: String): Pair<String, Boolean> {
        var u = url
        repeat(4) {
            if (!http(u)) throw IllegalArgumentException(Lang.t("Adres stacji musi zaczynać się od http:// lub https://"))
            if (u.substringBefore('?').lowercase().endsWith(".m3u8")) return u to true
            if (!playlistPath(u)) return u to false
            val (text, base) =
                client.newCall(Request.Builder().url(u).build()).execute().use { r ->
                    if (!r.isSuccessful) throw java.io.IOException(Lang.t("Stacja odpowiedziała błędem HTTP {0}.").replace("{0}", "${r.code}"))
                    (r.body?.byteStream()?.readNBytesCompat(256 * 1024)?.toString(Charsets.UTF_8) ?: "") to r.request.url.toString()
                }
            when (val next = parsePlaylist(text, base)) {
                null -> throw java.io.IOException(Lang.t("Lista stacji nie zawiera adresu strumienia."))
                "hls" -> return u to true
                else -> u = next
            }
        }
        throw java.io.IOException(Lang.t("Za dużo przekierowań list stacji."))
    }

    private fun java.io.InputStream.readNBytesCompat(limit: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(8192)
        while (out.size() < limit) {
            val n = read(buf, 0, minOf(buf.size, limit - out.size()))
            if (n < 0) break
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    /** Checks an address the user typed before it is saved: {url, name, codec, hls}. */
    fun probe(url: String): JSONObject {
        val (resolved, hls) = resolve(url)
        if (hls) return JSONObject().put("url", url).put("codec", "HLS").put("hls", true)
        client.newBuilder().readTimeout(8, TimeUnit.SECONDS).build()
            .newCall(Request.Builder().url(resolved).header("Icy-MetaData", "1").build()).execute().use { r ->
                if (!r.isSuccessful) throw java.io.IOException(Lang.t("Stacja odpowiedziała błędem HTTP {0}.").replace("{0}", "${r.code}"))
                val type = (r.header("Content-Type") ?: "").substringBefore(';').trim().lowercase()
                if (type.startsWith("text/html")) throw java.io.IOException(Lang.t("Pod tym adresem jest strona internetowa, a nie strumień radia."))
                val codec =
                    when {
                        type.contains("mpeg") || type.contains("mp3") -> "MP3"
                        type.contains("aac") -> "AAC"
                        type.contains("ogg") -> "OGG"
                        type.contains("mpegurl") -> "HLS"
                        else -> ""
                    }
                return JSONObject().put("url", url).put("name", r.header("icy-name") ?: JSONObject.NULL).put("codec", codec).put("hls", codec == "HLS")
            }
    }

    // Stations kept on the phone: favourites (from the app) and every station played,
    // so Android Auto, the notification and a restart can play them without the app.
    private fun prefs(context: Context) = context.getSharedPreferences("radio", 0)

    fun favorites(context: Context): List<Station> =
        runCatching { JSONArray(prefs(context).getString("favorites", "[]")).let { a -> (0 until a.length()).mapNotNull { Station.from(a.getJSONObject(it)) } } }
            .getOrDefault(emptyList())

    fun setFavorites(context: Context, list: List<Station>) {
        prefs(context).edit().putString("favorites", JSONArray(list.take(500).map { it.json() }).toString()).apply()
        list.forEach { remember(context, it) }
    }

    fun recent(context: Context): List<Station> =
        runCatching { JSONArray(prefs(context).getString("known", "[]")).let { a -> (0 until a.length()).mapNotNull { Station.from(a.getJSONObject(it)) } } }
            .getOrDefault(emptyList())

    fun remember(context: Context, s: Station) {
        val list = listOf(s) + recent(context).filter { it.id != s.id }
        prefs(context).edit().putString("known", JSONArray(list.take(200).map { it.json() }).toString()).apply()
    }

    fun known(context: Context, id: String): Station? =
        recent(context).firstOrNull { it.id == id } ?: favorites(context).firstOrNull { it.id == id }

    /** Playable item: the address must already be resolved ([resolve]) on a network thread. */
    fun item(s: Station, url: String = s.url, hls: Boolean = s.hls): MediaItem =
        MediaItem.Builder()
            .setMediaId(s.id)
            .setUri(url)
            .apply { if (hls) setMimeType(MimeTypes.APPLICATION_M3U8) }
            .setMediaMetadata(browse(s, playable = true))
            .build()

    fun browse(s: Station, playable: Boolean = true): MediaMetadata =
        MediaMetadata.Builder()
            .setTitle(s.name)
            .setArtist(s.name)
            .setStation(s.name)
            .setSubtitle(listOfNotNull(s.tags.firstOrNull(), s.codec.takeIf { it.isNotEmpty() }?.let { c -> if (s.bitrate > 0) "$c ${s.bitrate} kbps" else c }).joinToString(" · "))
            .setArtworkUri(s.logo.takeIf { it.startsWith("https://") }?.let(Uri::parse))
            .setIsPlayable(playable)
            .setIsBrowsable(false)
            .setMediaType(MediaMetadata.MEDIA_TYPE_RADIO_STATION)
            .setExtras(Bundle().apply { putString("radioUrl", s.url) })
            .build()
}
