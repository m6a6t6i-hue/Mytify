package pl.mytify.mytify

import android.content.Context
import android.net.Uri
import com.hierynomus.smbj.share.File as SmbFile
import java.io.InputStream
import org.json.JSONArray
import org.json.JSONObject

/**
 * Network sources on the phone. Protocol code only delivers bytes and folder lists;
 * identity, tags and playback stay in [Catalog] and the existing player.
 */
object NetworkSources {
    /** Only protocols that really work in this build. The UI offers nothing else. */
    val protocols = listOf("smb")

    @Volatile internal var shared: Catalog? = null

    private fun catalog(context: Context): Catalog =
        shared ?: synchronized(this) { shared ?: Catalog(context.applicationContext).also { shared = it } }

    fun settings(context: Context, id: String): SmbSettings =
        catalog(context).sourceSettings(id)?.let { SmbSettings.parse(it) }
            ?: throw SourceException("Źródło zostało usunięte.")

    private fun password(context: Context, id: String?, config: JSONObject): String =
        if (config.has("password") && !config.isNull("password")) config.getString("password")
        else id?.let { Secrets.load(context, it) } ?: ""

    /** Logs in and lists the chosen folder. Nothing is saved. */
    fun test(context: Context, id: String?, config: JSONObject): JSONObject {
        val s = SmbSettings.parse(config)
        val key = "test:" + sha("${s.host}\u0000${s.share}\u0000${s.user}".toByteArray())
        try {
            val folders = Smb.with(key, s, password(context, id, config)) { Smb.folders(it, s, "") }
            return obj("ok" to true, "folders" to JSONArray(folders))
        } finally {
            Smb.close(key)
        }
    }

    fun browse(context: Context, id: String?, config: JSONObject, path: String): JSONObject {
        val s = SmbSettings.parse(config).copy(folder = "")
        val key = "browse:" + sha("${s.host}\u0000${s.share}\u0000${s.user}".toByteArray())
        val relative = SmbSettings.segments(path).joinToString("/")
        try {
            val folders = Smb.with(key, s, password(context, id, config)) { Smb.folders(it, s, relative) }
            return obj("folders" to JSONArray(folders))
        } finally {
            Smb.close(key)
        }
    }

    /** Opens a track location for reading. Used by playback, tags and DLNA streaming. */
    fun open(context: Context, uri: Uri): Pair<SmbFile, Long> {
        val id = uri.authority ?: throw SourceException("Nieprawidłowy adres pliku.")
        val s = settings(context, id)
        // Locations keep the full path inside the share.
        val path = uri.pathSegments.joinToString("/")
        return Smb.with(id, s, Secrets.load(context, id) ?: "") { share ->
            val f = Smb.openFile(share, path)
            f to f.fileInformation.standardInformation.endOfFile
        }
    }

    /** Sequential stream from [offset], for serving a NAS track to a DLNA renderer. */
    fun stream(context: Context, uri: Uri, offset: Long): InputStream {
        val (file, size) = open(context, uri)
        return object : InputStream() {
            var position = offset
            override fun read(): Int {
                val b = ByteArray(1)
                return if (read(b, 0, 1) <= 0) -1 else b[0].toInt() and 0xff
            }

            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (position >= size) return -1
                val n = file.read(b, position, off, minOf(len.toLong(), size - position).toInt())
                if (n <= 0) return -1
                position += n
                return n
            }

            override fun close() {
                file.close()
            }
        }
    }

    /** Checks every share and stores online/offline, without touching the collection. */
    fun probe(context: Context) {
        val c = catalog(context)
        var changed = false
        for (id in c.networkSourceIds()) {
            val ok =
                runCatching {
                        val s = settings(context, id)
                        Smb.with(id, s, Secrets.load(context, id) ?: "") { it.folderExists(s.inside()) || s.folder.isEmpty() }
                    }
                    .getOrDefault(false)
            changed = c.setReachable(id, ok) || changed
        }
        if (changed) LibraryChanges.changed()
    }
}
