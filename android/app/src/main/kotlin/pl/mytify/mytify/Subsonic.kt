package pl.mytify.mytify

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import java.io.IOException
import java.security.MessageDigest
import java.security.SecureRandom
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject

/** OpenSubsonic / Subsonic server settings. The password is kept apart, in [Secrets]. */
data class ServerSettings(
    val name: String,
    val url: String,
    val user: String,
    val qualityWifi: String,
    val qualityMobile: String,
) {
    fun json(): JSONObject =
        obj(
            "protocol" to "subsonic",
            "name" to name,
            "url" to url,
            "user" to user,
            "qualityWifi" to qualityWifi,
            "qualityMobile" to qualityMobile,
        )

    companion object {
        fun parse(j: JSONObject): ServerSettings {
            val raw = j.optString("url").trim()
            require(raw.isNotEmpty()) { "Podaj adres serwera." }
            val u = (if ("://" in raw) raw else "https://$raw").toHttpUrlOrNull()
            require(u != null && (u.scheme == "https" || u.scheme == "http")) { "Adres serwera jest nieprawidłowy." }
            require(u.username.isEmpty() && u.password.isEmpty()) { "Nie wpisuj loginu ani hasła w adresie. Użyj pól poniżej." }
            // A pasted ".../rest/" or ".../app/" still means the server root.
            var segments = u.pathSegments.filter { it.isNotEmpty() }
            if (segments.lastOrNull() in setOf("rest", "app")) segments = segments.dropLast(1)
            val b = u.newBuilder().query(null).fragment(null).encodedPath("/")
            segments.forEach { b.addPathSegment(it) }
            if (segments.isNotEmpty()) b.addPathSegment("")
            val user = j.optString("user").trim()
            require(user.isNotEmpty()) { "Podaj nazwę użytkownika." }
            require(user.length <= 256) { "Nazwa użytkownika jest nieprawidłowa." }
            fun quality(k: String) = if (j.optString(k) == "saver") "saver" else "original"
            return ServerSettings(
                j.optString("name").trim().take(80).ifEmpty { u.host },
                b.build().toString(),
                user,
                quality("qualityWifi"),
                quality("qualityMobile"),
            )
        }
    }
}

class SubsonicClient(private val s: ServerSettings, private val password: String) {
    data class Song(
        val id: String,
        val title: String,
        val album: String,
        val artist: String,
        val albumArtist: String,
        val track: Int,
        val disc: Int,
        val durationMs: Long,
        val size: Long,
        val suffix: String,
        val sampleRate: Int,
        val bitDepth: Int,
        val cover: String?,
        val starred: Boolean,
        val path: String,
    ) {
        val format: String
            get() =
                when (suffix) {
                    "flac" -> "FLAC"
                    "mp3" -> "MP3"
                    "m4a", "mp4", "alac" -> "M4A"
                    "aac" -> "AAC"
                    "wav" -> "WAV"
                    "aif", "aiff" -> "AIFF"
                    "opus" -> "OPUS"
                    "ogg", "oga" -> "OGG"
                    else -> "AUDIO"
                }

        /** Lossy formats have no PCM bit depth, whatever a server reports. */
        val pcmDepth: Int
            get() = if (suffix in setOf("flac", "wav", "aif", "aiff", "alac", "m4a", "ape", "wv")) bitDepth else 0

        val version: String
            get() = "$size|$durationMs|$suffix"

        val fileName: String
            get() = path.substringAfterLast('/').ifEmpty { if (suffix.isEmpty()) title else "$title.$suffix" }

        companion object {
            fun parse(v: JSONObject): Song? {
                val id = v.optString("id")
                if (id.isEmpty() || v.optBoolean("isDir") || v.optBoolean("isVideo")) return null
                val albumArtist =
                    v.optString("displayAlbumArtist").ifEmpty {
                        v.optJSONArray("albumArtists")?.optJSONObject(0)?.optString("name") ?: ""
                    }
                return Song(
                    id,
                    v.optString("title"),
                    v.optString("album"),
                    v.optString("artist"),
                    albumArtist,
                    v.optInt("track"),
                    v.optInt("discNumber"),
                    v.optLong("duration") * 1000,
                    v.optLong("size"),
                    v.optString("suffix").lowercase(),
                    v.optInt("samplingRate"),
                    v.optInt("bitDepth").coerceIn(0, 64),
                    v.optString("coverArt").ifEmpty { null },
                    v.has("starred") && !v.isNull("starred"),
                    v.optString("path"),
                )
            }
        }
    }

    data class Playlist(val id: String, val name: String, val songs: List<Song>)

    private val base = s.url.toHttpUrlOrNull()!!

    /** Token login: md5(password + salt). The password itself never travels. */
    fun url(endpoint: String, params: List<Pair<String, String>> = emptyList()): HttpUrl {
        val salt = ByteArray(8).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
        val token =
            MessageDigest.getInstance("MD5").digest((password + salt).toByteArray()).joinToString("") { "%02x".format(it) }
        val b = base.newBuilder().addPathSegment("rest").addPathSegment(endpoint)
        listOf("u" to s.user, "t" to token, "s" to salt, "v" to "1.16.1", "c" to "Mytify", "f" to "json")
            .plus(params)
            .forEach { (k, v) -> b.addQueryParameter(k, v) }
        return b.build()
    }

    private fun apiError(code: Int, message: String) =
        SourceException(
            when (code) {
                40 -> "Nieprawidłowy użytkownik lub hasło."
                41 -> "Serwer nie obsługuje logowania tokenem. Połącz się przez HTTPS."
                50 -> "To konto nie ma uprawnień do tej operacji."
                70 -> "Nie znaleziono na serwerze."
                20, 30 -> "Ta wersja serwera nie jest obsługiwana."
                else -> if (message.isEmpty()) "Serwer odrzucił żądanie." else "Serwer odrzucił żądanie: ${message.take(120)}"
            }
        )

    fun call(endpoint: String, params: List<Pair<String, String>> = emptyList()): JSONObject {
        val response =
            try {
                WebDav.client.newCall(Request.Builder().url(url(endpoint, params)).header("User-Agent", "Mytify").build()).execute()
            } catch (e: IOException) {
                throw WebDav.friendly(e)
            }
        response.use { r ->
            if (r.request.url.host != base.host) throw SourceException("Serwer przekierowuje na inny adres. Wpisz docelowy adres serwera.")
            if (r.code == 401) throw SourceException("Nieprawidłowy użytkownik lub hasło.")
            if (!r.isSuccessful)
                throw SourceException(if (r.code == 404) "Pod tym adresem nie ma serwera Subsonic." else "Serwer odrzucił żądanie (HTTP ${r.code}).")
            val body = runCatching { JSONObject(r.body!!.string()).getJSONObject("subsonic-response") }.getOrNull()
                ?: throw SourceException("Pod tym adresem nie ma serwera Subsonic.")
            if (body.optString("status") != "ok") {
                val e = body.optJSONObject("error")
                throw apiError(e?.optInt("code") ?: 0, e?.optString("message") ?: "")
            }
            return body
        }
    }

    /** "Połączono z navidrome 0.58 (OpenSubsonic)." */
    fun describe(): String {
        val r = call("ping")
        val name =
            listOfNotNull(r.optString("type").ifEmpty { null }, r.optString("serverVersion").ifEmpty { null }).joinToString(" ")
                .ifEmpty { "Subsonic API ${r.optString("version")}" }
        return if (r.optBoolean("openSubsonic")) "Połączono z $name (OpenSubsonic)." else "Połączono z $name."
    }

    private fun songs(array: JSONArray?) = (0 until (array?.length() ?: 0)).mapNotNull { Song.parse(array!!.getJSONObject(it)) }

    fun songs(offset: Int, count: Int): List<Song> =
        songs(
            call(
                    "search3",
                    listOf("query" to "", "artistCount" to "0", "albumCount" to "0", "songCount" to "$count", "songOffset" to "$offset"),
                )
                .optJSONObject("searchResult3")
                ?.optJSONArray("song")
        )

    fun songsByAlbums(each: (List<Song>) -> Unit) {
        var offset = 0
        while (true) {
            val albums =
                call("getAlbumList2", listOf("type" to "alphabeticalByName", "size" to "500", "offset" to "$offset"))
                    .optJSONObject("albumList2")
                    ?.optJSONArray("album") ?: return
            if (albums.length() == 0) return
            for (i in 0 until albums.length()) {
                val id = albums.getJSONObject(i).optString("id")
                each(songs(call("getAlbum", listOf("id" to id)).optJSONObject("album")?.optJSONArray("song")))
            }
            offset += albums.length()
        }
    }

    fun cover(id: String): ByteArray? =
        runCatching {
                WebDav.client.newCall(Request.Builder().url(url("getCoverArt", listOf("id" to id, "size" to "600"))).build()).execute().use {
                    if (it.isSuccessful && it.header("Content-Type").orEmpty().startsWith("image/")) it.body!!.bytes() else null
                }
            }
            .getOrNull()

    fun star(id: String, starred: Boolean) {
        call(if (starred) "star" else "unstar", listOf("id" to id))
    }

    fun scrobble(id: String, time: Long) {
        call("scrobble", listOf("id" to id, "time" to "$time", "submission" to "true"))
    }

    fun playlists(): List<Playlist> {
        val list = call("getPlaylists").optJSONObject("playlists")?.optJSONArray("playlist") ?: return emptyList()
        return (0 until list.length()).map { i ->
            val id = list.getJSONObject(i).getString("id")
            val p = call("getPlaylist", listOf("id" to id)).getJSONObject("playlist")
            Playlist(id, p.optString("name", "Playlista"), songs(p.optJSONArray("entry")))
        }
    }

    /** Creates a playlist, or replaces the songs of an existing one. */
    fun savePlaylist(id: String?, name: String, songs: List<String>): String {
        val params = (if (id != null) listOf("playlistId" to id) else listOf("name" to name)) + songs.map { "songId" to it }
        val r = call("createPlaylist", params)
        if (id != null) {
            call("updatePlaylist", listOf("playlistId" to id, "name" to name))
            return id
        }
        return r.optJSONObject("playlist")?.optString("id")?.ifEmpty { null } ?: throw SourceException("Serwer nie zwrócił playlisty.")
    }

    /**
     * Stream address for the player. Original file unless the user chose saving data
     * for the current network type. Never shown or stored.
     */
    fun streamUrl(context: Context, song: String): HttpUrl {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val caps = cm?.getNetworkCapabilities(cm.activeNetwork)
        val cellular = caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true
        val saver = (if (cellular) s.qualityMobile else s.qualityWifi) == "saver"
        return url(
            "stream",
            listOf("id" to song) + if (saver) listOf("format" to "mp3", "maxBitRate" to "192") else listOf("format" to "raw"),
        )
    }

    companion object {
        /** subsonic://<source id>/<song id> */
        fun uri(sourceId: String, song: String): Uri = Uri.Builder().scheme("subsonic").authority(sourceId).appendPath(song).build()
    }
}
