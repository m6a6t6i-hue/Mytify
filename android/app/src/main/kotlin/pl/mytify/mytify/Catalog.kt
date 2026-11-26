package pl.mytify.mytify

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.DocumentsContract as DC
import android.provider.OpenableColumns
import android.util.AtomicFile
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

internal fun obj(vararg fields: Pair<String, Any?>) =
    JSONObject().apply { fields.forEach { (k, v) -> put(k, v ?: JSONObject.NULL) } }

internal fun sha(bytes: ByteArray) =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

internal fun JSONArray.strings() = (0 until length()).map { getString(it) }

internal fun readLimited(stream: java.io.InputStream, limit: Int): ByteArray {
    val out = ByteArrayOutputStream()
    val buffer = ByteArray(16384)
    while (true) {
        val n = stream.read(buffer)
        if (n < 0) break
        require(out.size() + n <= limit) { "Plik jest za duży" }
        out.write(buffer, 0, n)
    }
    return out.toByteArray()
}

private val offlineOwnershipLock = Any()

class Catalog(private val context: Context) :
    SQLiteOpenHelper(context, "catalog-android.sqlite3", null, 4) {
    val cancelled = AtomicBoolean(false)
    private val resolver = context.contentResolver
    private val covers = File(context.filesDir, "covers").apply { mkdirs() }
    private val extensions =
        setOf("mp3", "flac", "wav", "m4a", "aac", "ogg", "opus", "aif", "aiff", "ape", "wv")

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE tracks(id TEXT PRIMARY KEY,raw TEXT NOT NULL,patch TEXT NOT NULL DEFAULT '{}',liked INTEGER NOT NULL DEFAULT 0,added INTEGER NOT NULL)"
        )
        db.execSQL(
            "CREATE TABLE sources(id TEXT PRIMARY KEY,uri TEXT NOT NULL,name TEXT NOT NULL,kind TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'partial',scanned INTEGER NOT NULL DEFAULT 0)"
        )
        db.execSQL(
            "CREATE TABLE locations(uri TEXT NOT NULL,source TEXT NOT NULL,track TEXT NOT NULL,name TEXT NOT NULL,available INTEGER NOT NULL DEFAULT 1,size INTEGER NOT NULL DEFAULT -1,modified INTEGER NOT NULL DEFAULT -1,PRIMARY KEY(uri,source))"
        )
        db.execSQL(
            "CREATE TABLE source_settings(source TEXT PRIMARY KEY,protocol TEXT NOT NULL,settings TEXT NOT NULL)"
        )
        createSyncTables(db)
        db.execSQL("CREATE INDEX location_track ON locations(track)")
        db.execSQL("CREATE TABLE ignored(uri TEXT PRIMARY KEY)")
        PlaylistStore.create(db)
    }

    override fun onUpgrade(db: SQLiteDatabase, old: Int, new: Int) {
        if (old < 2) PlaylistStore.create(db)
        if (old < 3) {
            // 0.15: network sources. Additive only: existing tracks, likes and playlists stay.
            val columns =
                db.rawQuery("PRAGMA table_info(locations)", null).use { c ->
                    buildSet { while (c.moveToNext()) add(c.getString(1)) }
                }
            if ("size" !in columns) db.execSQL("ALTER TABLE locations ADD COLUMN size INTEGER NOT NULL DEFAULT -1")
            if ("modified" !in columns)
                db.execSQL("ALTER TABLE locations ADD COLUMN modified INTEGER NOT NULL DEFAULT -1")
            db.execSQL(
                "CREATE TABLE IF NOT EXISTS source_settings(source TEXT PRIMARY KEY,protocol TEXT NOT NULL,settings TEXT NOT NULL)"
            )
        }
        // 0.17: music servers (favourites and plays waiting to be sent, linked playlists).
        if (old < 4) createSyncTables(db)
    }

    private fun createSyncTables(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE IF NOT EXISTS remote_art(source TEXT NOT NULL,art TEXT NOT NULL,cover TEXT NOT NULL,PRIMARY KEY(source,art))")
        db.execSQL("CREATE TABLE IF NOT EXISTS pending_sync(id INTEGER PRIMARY KEY AUTOINCREMENT,source TEXT NOT NULL,kind TEXT NOT NULL,item TEXT NOT NULL,value TEXT NOT NULL,created INTEGER NOT NULL)")
        Downloads.create(db)
        db.execSQL("CREATE TABLE IF NOT EXISTS remote_playlists(source TEXT NOT NULL,remote TEXT NOT NULL,local TEXT NOT NULL,server_hash TEXT NOT NULL,local_hash TEXT NOT NULL,PRIMARY KEY(source,remote))")
    }

    override fun onConfigure(db: SQLiteDatabase) {
        db.enableWriteAheadLogging()
    }

    private fun checkCancel() {
        if (cancelled.get()) throw CancellationException()
    }

    internal fun cv(vararg fields: Pair<String, Any?>) =
        ContentValues().apply {
            fields.forEach { (k, v) ->
                when (v) {
                    null -> putNull(k)
                    is Int -> put(k, v)
                    is Long -> put(k, v)
                    else -> put(k, v.toString())
                }
            }
        }

    fun sourceList(): JSONArray {
        val out = JSONArray()
        readableDatabase
            .rawQuery("SELECT id,uri,name,kind,state,scanned FROM sources ORDER BY name", null)
            .use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0)
                    readableDatabase
                        .rawQuery(
                            "SELECT COUNT(*),COALESCE(SUM(available),0) FROM locations WHERE source=?",
                            arrayOf(id),
                        )
                        .use { n ->
                            n.moveToFirst()
                            val kind = c.getString(3)
                            val network = if (kind == "smb" || kind == "webdav" || kind == "subsonic") sourceSettings(id) else null
                            val address =
                                network?.let {
                                    when (kind) {
                                        "smb" -> SmbSettings.parse(it).address
                                        "webdav" -> DavSettings.parse(it).address
                                        else -> ServerSettings.parse(it).url
                                    }
                                }
                            out.put(
                                obj(
                                    "id" to id,
                                    "protocol" to if (network != null) kind else "local",
                                    "address" to address,
                                    "capabilities" to
                                        JSONArray(
                                            if (kind == "subsonic")
                                                listOf("search", "tags", "artwork", "stream", "seek", "refresh", "syncLikes", "syncPlaylists", "scrobble")
                                            else if (kind == "smb" || kind == "webdav" || kind == "folder")
                                                listOf("browse", "scan", "tags", "artwork", "stream", "seek", "refresh")
                                            else listOf("tags", "artwork", "stream", "seek")
                                        ),
                                    "path" to
                                        if (address != null) address
                                        else if (kind == "folder") c.getString(1)
                                        else "Pliki wybrane w telefonie",
                                    "name" to c.getString(2),
                                    "kind" to c.getString(3),
                                    "state" to c.getString(4),
                                    "lastScan" to c.getLong(5),
                                    "files" to n.getInt(0),
                                    "availableFiles" to n.getInt(1),
                                )
                            )
                        }
                }
            }
        return out
    }

    fun load(id: String? = null, includeCover: Boolean = true): JSONArray {
        val out = JSONArray()
        readableDatabase
            .rawQuery(
                "SELECT id,raw,patch,liked,added FROM tracks" +
                    (if (id == null) " ORDER BY added DESC,id" else " WHERE id=?"),
                id?.let { arrayOf(it) },
            )
            .use { c ->
                while (c.moveToNext()) {
                    val raw = JSONObject(c.getString(1))
                    val patch = JSONObject(c.getString(2))
                    patch.keys().forEach { raw.put(it, patch.get(it)) }
                    raw.put("id", c.getString(0))
                        .put("liked", c.getInt(3) != 0)
                        .put("addedAt", c.getLong(4))
                        .put("edited", patch.length() > 0)
                    readableDatabase
                        .rawQuery(
                            "SELECT COUNT(DISTINCT l.uri),COALESCE(MAX(CASE WHEN l.available=1 AND COALESCE(s.state,'online')<>'offline' THEN 1 ELSE 0 END),0),COALESCE(MAX(CASE WHEN l.source LIKE 'offline:%' AND l.available=1 THEN 1 ELSE 0 END),0),COALESCE(MAX(CASE WHEN l.uri LIKE 'smb:%' OR l.uri LIKE 'dav:%' OR l.uri LIKE 'subsonic:%' THEN 1 ELSE 0 END),0) FROM locations l LEFT JOIN sources s ON s.id=l.source WHERE l.track=?",
                            arrayOf(c.getString(0)),
                        )
                        .use { n ->
                            n.moveToFirst()
                            raw.put("locationCount", n.getInt(0)).put("available", n.getInt(1) > 0)
                                .put("offline", n.getInt(2) > 0).put("remote", n.getInt(3) > 0)
                        }
                    val hash = raw.optString("cover")
                    raw.put(
                        "cover",
                        if (includeCover)
                            coverFile(hash)?.let { Uri.fromFile(it).toString() } ?: JSONObject.NULL
                        else JSONObject.NULL,
                    )
                    out.put(raw)
                }
            }
        return out
    }

    fun track(id: String): JSONObject =
        load(id, false).let {
            require(it.length() > 0) { "Nie znaleziono utworu" }
            it.getJSONObject(0)
        }

    fun uri(id: String): Uri {
        readableDatabase
            .rawQuery(
                // Local copies first, the NAS last; a share known to be offline is skipped
                // at once, so Android Auto never waits for an unreachable server.
                "SELECT l.uri FROM locations l LEFT JOIN sources s ON s.id=l.source WHERE l.track=? AND l.available=1 AND COALESCE(s.state,'online')<>'offline' ORDER BY CASE WHEN l.source LIKE 'offline:%' THEN 0 WHEN l.uri LIKE 'smb:%' THEN 2 WHEN l.uri LIKE 'dav:%' OR l.uri LIKE 'subsonic:%' THEN 3 ELSE 1 END,l.uri LIMIT 1",
                arrayOf(id),
            )
            .use { if (it.moveToFirst()) return Uri.parse(it.getString(0)) }
        error("Plik jest niedostępny. Wskaż źródło ponownie i wykonaj skan.")
    }

    fun liked(id: String): Boolean =
        readableDatabase.rawQuery("SELECT liked FROM tracks WHERE id=?", arrayOf(id)).use {
            it.moveToFirst() && it.getInt(0) != 0
        }

    fun like(id: String, value: Boolean) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.update("tracks", cv("liked" to if (value) 1 else 0), "id=?", arrayOf(id))
            // Music servers keep their own favourites: remember the change until it is sent.
            serverLocations(id).forEach { (source, song) ->
                db.delete("pending_sync", "source=? AND kind='star' AND item=?", arrayOf(source, song))
                db.insertOrThrow(
                    "pending_sync",
                    null,
                    cv("source" to source, "kind" to "star", "item" to song, "value" to if (value) "1" else "0", "created" to System.currentTimeMillis()),
                )
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    /** (source, song id) of a track on music servers. */
    fun serverLocations(id: String): List<Pair<String, String>> =
        readableDatabase.rawQuery("SELECT source,uri FROM locations WHERE track=? AND uri LIKE 'subsonic:%'", arrayOf(id)).use { c ->
            buildList { while (c.moveToNext()) add(c.getString(0) to Uri.parse(c.getString(1)).pathSegments.first()) }
        }

    /** A finished play: scrobbled now or when the server is reachable again. */
    fun played(id: String) {
        serverLocations(id).forEach { (source, song) ->
            writableDatabase.insertOrThrow(
                "pending_sync",
                null,
                cv("source" to source, "kind" to "scrobble", "item" to song, "value" to "", "created" to System.currentTimeMillis()),
            )
        }
    }

    fun server(id: String): SubsonicClient =
        SubsonicClient(
            ServerSettings.parse(sourceSettings(id) ?: throw SourceException("Źródło zostało usunięte.")),
            Secrets.load(context, id) ?: "",
        )

    /** Sends waiting favourites and plays; stops at the first network error and keeps the rest. */
    fun flushPending(source: String): Int {
        val rows =
            readableDatabase.rawQuery("SELECT id,kind,item,value,created FROM pending_sync WHERE source=? ORDER BY id", arrayOf(source)).use { c ->
                buildList { while (c.moveToNext()) add(listOf(c.getString(0), c.getString(1), c.getString(2), c.getString(3), c.getString(4))) }
            }
        if (rows.isEmpty()) return 0
        val client = server(source)
        var sent = 0
        for ((row, kind, item, value, created) in rows) {
            try {
                when (kind) {
                    "star" -> client.star(item, value == "1")
                    "scrobble" -> client.scrobble(item, created.toLong())
                }
                sent++
            } catch (e: SourceException) {
                if (e.message != "Nie znaleziono na serwerze.") throw e
            }
            writableDatabase.delete("pending_sync", "id=?", arrayOf(row))
        }
        return sent
    }

    fun remove(id: String) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.execSQL(
                "INSERT OR IGNORE INTO ignored SELECT uri FROM locations WHERE track=?",
                arrayOf(id),
            )
            db.delete("locations", "track=?", arrayOf(id))
            db.delete("tracks", "id=?", arrayOf(id))
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    fun forget(id: String) {
        if (sourceSettings(id) != null) {
            Secrets.delete(context, id)
            Smb.close(id)
        }
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.delete("locations", "source=?", arrayOf(id))
            db.delete("source_settings", "source=?", arrayOf(id))
            for (t in listOf("pending_sync", "remote_playlists", "remote_art")) db.delete(t, "source=?", arrayOf(id))
            db.delete("sources", "id=?", arrayOf(id))
            db.execSQL("DELETE FROM tracks WHERE id NOT IN (SELECT track FROM locations)")
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    fun edit(edits: JSONArray) {
        require(edits.length() in 1..5000)
        val db = writableDatabase
        db.beginTransaction()
        try {
            for (i in 0 until edits.length()) {
                val e = edits.getJSONObject(i)
                val id = e.getString("id")
                val change = e.getJSONObject("patch")
                val patch =
                    db.rawQuery("SELECT patch FROM tracks WHERE id=?", arrayOf(id)).use {
                        require(it.moveToFirst())
                        JSONObject(it.getString(0))
                    }
                change.keys().forEach { k ->
                    require(
                        k in
                            setOf(
                                "title",
                                "artist",
                                "album",
                                "albumArtist",
                                "trackNumber",
                                "discNumber",
                                "cover",
                                "metadataSource",
                                "releaseId",
                            )
                    ) {
                        "Nieznane pole: $k"
                    }
                    val v = change.get(k)
                    if (k == "trackNumber" || k == "discNumber")
                        require(v is Number && v.toInt() in 0..9999)
                    else {
                        require(v is String && v.length <= 2048)
                        if (k == "cover" && v.isNotEmpty()) require(coverFile(v) != null)
                    }
                    patch.put(k, v)
                }
                db.update("tracks", cv("patch" to patch.toString()), "id=?", arrayOf(id))
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    fun reset(ids: List<String>) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            ids.forEach { db.update("tracks", cv("patch" to "{}"), "id=?", arrayOf(it)) }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    fun coverFile(hash: String): File? =
        if (hash.matches(Regex("[a-f0-9]{64}"))) File(covers, hash).takeIf { it.isFile } else null

    fun storeCover(bytes: ByteArray): JSONObject {
        require(bytes.size <= 8 * 1024 * 1024) { "Okładka przekracza 8 MB" }
        val b = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, b)
        require(b.outWidth in 1..30000 && b.outHeight in 1..30000) { "Nieprawidłowy obraz" }
        val options =
            BitmapFactory.Options().apply {
                inSampleSize = 1
                while (maxOf(b.outWidth, b.outHeight) / inSampleSize > 1200) inSampleSize *= 2
            }
        val bitmap =
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                ?: error("Nie można odczytać obrazu")
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 88, out)
        bitmap.recycle()
        val data = out.toByteArray()
        val hash = sha(data)
        val target = File(covers, hash)
        if (!target.isFile) {
            val tmp = File(covers, "$hash.tmp")
            tmp.writeBytes(data)
            check(tmp.renameTo(target))
        }
        return obj("hash" to hash, "uri" to Uri.fromFile(target).toString())
    }

    fun artwork(id: String): Uri? {
        readableDatabase.rawQuery("SELECT raw,patch FROM tracks WHERE id=?", arrayOf(id)).use { c ->
            if (c.moveToFirst()) {
                val raw = JSONObject(c.getString(0))
                val patch = JSONObject(c.getString(1))
                return coverFile(patch.optString("cover", raw.optString("cover")))?.let {
                    Uri.fromFile(it)
                }
            }
        }
        return null
    }

    data class Doc(val uri: Uri, val name: String, val size: Long)

    private fun document(uri: Uri): Doc {
        if (uri.scheme == "file") {
            val f = File(uri.path!!).canonicalFile
            require(
                f.parentFile == File(context.filesDir, "offline-music").canonicalFile && f.isFile
            )
            return Doc(uri, f.name, f.length())
        }

        resolver
            .query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )
            ?.use { c ->
                require(c.moveToFirst()) { "Plik jest niedostępny" }
                return Doc(uri, c.getString(0) ?: "utwór", if (c.isNull(1)) 0 else c.getLong(1))
            }
        error("Źródło nie odpowiada")
    }

    private fun enumerate(tree: Uri): List<Doc> {
        val todo = ArrayDeque<String>()
        todo.add(DC.getTreeDocumentId(tree))
        val visited = HashSet<String>()
        val out = mutableListOf<Doc>()
        while (todo.isNotEmpty()) {
            checkCancel()
            val id = todo.removeFirst()
            if (!visited.add(id)) continue
            require(visited.size + out.size <= 100000) { "Wybierz mniejszy folder" }
            val cursor =
                resolver.query(
                    DC.buildChildDocumentsUriUsingTree(tree, id),
                    arrayOf(
                        DC.Document.COLUMN_DOCUMENT_ID,
                        DC.Document.COLUMN_DISPLAY_NAME,
                        DC.Document.COLUMN_MIME_TYPE,
                        DC.Document.COLUMN_SIZE,
                    ),
                    null,
                    null,
                    null,
                ) ?: error("Źródło nie odpowiada")
            cursor.use { c ->
                while (c.moveToNext()) {
                    checkCancel()
                    val child = c.getString(0)
                    val name = c.getString(1) ?: "utwór"
                    if (c.getString(2) == DC.Document.MIME_TYPE_DIR) todo.add(child)
                    else if (name.substringAfterLast('.').lowercase() in extensions)
                        out.add(
                            Doc(
                                DC.buildDocumentUriUsingTree(tree, child),
                                name,
                                if (c.isNull(3)) 0 else c.getLong(3),
                            )
                        )
                }
            }
        }
        return out
    }

    fun addSource(uris: List<Uri>, folder: Boolean, relink: String? = null): String {
        require(uris.isNotEmpty())
        val root =
            if (folder) uris.first().toString()
            else JSONArray(uris.map { it.toString() }.sorted()).toString()
        val id = relink ?: sha(root.toByteArray())
        val name =
            if (folder)
                DC.getTreeDocumentId(uris.first())
                    .substringAfterLast('/')
                    .substringAfter(':')
                    .ifEmpty { "Muzyka" }
            else "Wybrane pliki (${uris.size})"
        val db = writableDatabase
        if (relink != null)
            require(
                db.rawQuery("SELECT id FROM sources WHERE id=? AND kind='folder'", arrayOf(id))
                    .use { it.moveToFirst() }
            )
        db.insertWithOnConflict(
            "sources",
            null,
            cv(
                "id" to id,
                "uri" to root,
                "name" to name,
                "kind" to if (folder) "folder" else "files",
                "state" to "partial",
                "scanned" to 0,
            ),
            SQLiteDatabase.CONFLICT_REPLACE,
        )
        return id
    }

    fun sourceSettings(id: String): JSONObject? =
        readableDatabase.rawQuery("SELECT settings FROM source_settings WHERE source=?", arrayOf(id)).use {
            if (it.moveToFirst()) JSONObject(it.getString(0)) else null
        }

    fun networkSourceIds(): List<String> =
        readableDatabase.rawQuery("SELECT id FROM sources WHERE kind IN ('smb','webdav','subsonic')", null).use { c ->
            buildList { while (c.moveToNext()) add(c.getString(0)) }
        }

    /** Stores reachability. Returns true when the state changed. */
    fun setReachable(id: String, reachable: Boolean): Boolean {
        val db = writableDatabase
        val (state, scanned) =
            db.rawQuery("SELECT state,scanned FROM sources WHERE id=?", arrayOf(id)).use {
                if (!it.moveToFirst()) return false
                it.getString(0) to it.getLong(1)
            }
        val next =
            when {
                !reachable -> "offline"
                state == "offline" -> if (scanned > 0) "online" else "partial"
                else -> state
            }
        if (next == state) return false
        db.update("sources", cv("state" to next), "id=?", arrayOf(id))
        return true
    }

    /** Adds or edits an SMB share. The password goes to [Secrets], never to the catalog. */
    /** Adds or edits a network source of any supported protocol. */
    fun saveNetwork(existing: String?, config: JSONObject): String =
        when (config.optString("protocol")) {
            "webdav" -> saveDav(existing, config)
            "subsonic" -> saveServer(existing, config)
            else -> saveSmb(existing, config)
        }

    private fun saveServer(existing: String?, config: JSONObject): String {
        val s = ServerSettings.parse(config)
        val id = existing ?: sha("subsonic\u0000${s.url.lowercase()}|${s.user}".toByteArray())
        val db = writableDatabase
        val previous =
            db.rawQuery("SELECT kind FROM sources WHERE id=?", arrayOf(id)).use { if (it.moveToFirst()) it.getString(0) else null }
        if (existing == null) require(previous == null) { "Ten serwer jest już dodany." }
        else require(previous == "subsonic") { "Nie znaleziono źródła." }
        if (config.has("password") && !config.isNull("password")) Secrets.store(context, id, config.getString("password"))
        db.beginTransaction()
        try {
            if (previous == null)
                db.insertOrThrow(
                    "sources",
                    null,
                    cv("id" to id, "uri" to "subsonic://$id", "name" to s.name, "kind" to "subsonic", "state" to "partial", "scanned" to 0),
                )
            else db.update("sources", cv("name" to s.name), "id=?", arrayOf(id))
            db.insertWithOnConflict(
                "source_settings",
                null,
                cv("source" to id, "protocol" to "subsonic", "settings" to s.json().toString()),
                SQLiteDatabase.CONFLICT_REPLACE,
            )
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        return id
    }

    /**
     * Imports the server's library through its API (no folder rescans): ids from source and
     * song id, tags and covers from the server, favourites reconciled with waiting changes.
     */
    private fun scanServer(id: String, name: String, report: JSONObject, bump: (String) -> Unit, progress: (Int, Int, String) -> Unit) {
        val errors = report.getJSONArray("errors")
        progress(0, 0, "Łączenie z $name…")
        val client =
            try {
                server(id).also { it.describe() }
            } catch (e: Exception) {
                writableDatabase.update("sources", cv("state" to "offline"), "id=?", arrayOf(id))
                bump("offlineSources")
                errors.put("$name: ${WebDav.friendly(e).message}")
                return
            }
        runCatching { flushPending(id) }.onFailure { errors.put("$name: ${it.message}") }
        val seen = HashSet<String>()
        val covers = HashMap<String, String>()
        var count = 0
        var complete = true
        val handle = { songs: List<SubsonicClient.Song> ->
            for (song in songs) {
                checkCancel()
                count++
                progress(count, 0, song.title)
                try {
                    val u = SubsonicClient.uri(id, song.id).toString()
                    seen.add(u)
                    val cover =
                        song.cover?.let { art ->
                            covers.getOrPut(art) {
                                readableDatabase.rawQuery("SELECT cover FROM remote_art WHERE source=? AND art=?", arrayOf(id, art)).use {
                                    if (it.moveToFirst()) it.getString(0) else null
                                }
                                    ?: (client.cover(art)?.let { runCatching { storeCover(it).getString("hash") }.getOrNull() } ?: "").also {
                                        writableDatabase.insertWithOnConflict(
                                            "remote_art", null, cv("source" to id, "art" to art, "cover" to it), SQLiteDatabase.CONFLICT_REPLACE,
                                        )
                                    }
                            }
                        } ?: ""
                    val track = sha("mytify-remote-v1\u0000$id\u0000${song.id}".toByteArray())
                    val raw =
                        obj(
                            "title" to song.title.ifEmpty { song.fileName.substringBeforeLast('.') },
                            "artist" to song.artist,
                            "album" to song.album,
                            "albumArtist" to song.albumArtist,
                            "fileName" to song.fileName,
                            "format" to song.format,
                            "size" to song.size,
                            "durationMs" to song.durationMs,
                            "trackNumber" to song.track,
                            "discNumber" to song.disc,
                            "sampleRate" to song.sampleRate,
                            "bitDepth" to song.pcmDepth,
                            "managed" to false,
                            "metadataSource" to "",
                            "cover" to cover,
                        )
                    val version = song.version.hashCode().toLong()
                    val prior =
                        readableDatabase.rawQuery("SELECT track,modified FROM locations WHERE uri=? AND source=?", arrayOf(u, id)).use {
                            if (it.moveToFirst()) it.getString(0) to it.getLong(1) else null
                        }
                    val exists = readableDatabase.rawQuery("SELECT id FROM tracks WHERE id=?", arrayOf(track)).use { it.moveToFirst() }
                    if (exists) writableDatabase.update("tracks", cv("raw" to raw.toString()), "id=?", arrayOf(track))
                    record(id, u, song.fileName, track, song.size, version, prior?.first, exists, raw)
                    bump(if (prior == null) "added" else if (prior.second == version) "unchanged" else "updated")
                    // The server's favourite wins unless a local change is still waiting.
                    val waiting =
                        readableDatabase.rawQuery("SELECT id FROM pending_sync WHERE source=? AND kind='star' AND item=?", arrayOf(id, song.id)).use {
                            it.moveToFirst()
                        }
                    if (!waiting) writableDatabase.update("tracks", cv("liked" to if (song.starred) 1 else 0), "id=?", arrayOf(track))
                } catch (x: CancellationException) {
                    throw x
                } catch (x: Exception) {
                    if (errors.length() < 100) errors.put("${song.title}: ${WebDav.friendly(x).message}")
                }
            }
        }
        try {
            var offset = 0
            while (true) {
                val page = client.songs(offset, 500)
                if (page.isEmpty()) break
                offset += page.size
                handle(page)
            }
            if (offset == 0) client.songsByAlbums { handle(it) }
        } catch (x: CancellationException) {
            throw x
        } catch (x: Exception) {
            complete = false
            errors.put("$name: ${WebDav.friendly(x).message}")
        }
        val db = writableDatabase
        db.beginTransaction()
        try {
            if (complete)
                db.rawQuery("SELECT uri,available FROM locations WHERE source=?", arrayOf(id)).use { c ->
                    while (c.moveToNext()) if (c.getString(0) !in seen) {
                        if (c.getInt(1) > 0) bump("missing")
                        db.update("locations", cv("available" to 0), "source=? AND uri=?", arrayOf(id, c.getString(0)))
                    }
                }
            db.update("sources", cv("state" to if (complete) "online" else "partial", "scanned" to System.currentTimeMillis()), "id=?", arrayOf(id))
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        if (complete) runCatching { syncPlaylists(id, client) }.onFailure { errors.put("$name: playlisty: ${WebDav.friendly(it).message}") }
        progress(count, count, "Gotowe")
    }

    data class PlaylistSync(var imported: Int = 0, var updated: Int = 0, var sent: Int = 0, var conflicts: Int = 0)

    private fun fingerprint(name: String, ids: List<String>) = sha((name + "\n" + ids.joinToString("\n")).toByteArray())

    /**
     * Server playlists appear as local ones and local edits go back. When both sides changed,
     * nothing is overwritten: the server version arrives as a separate copy. Same rules as PC.
     */
    fun syncPlaylists(source: String, client: SubsonicClient = server(source)): PlaylistSync {
        val result = PlaylistSync()
        val store = PlaylistStore(this)
        val server = client.playlists()
        val songOf = HashMap<String, String>()
        readableDatabase.rawQuery("SELECT track,uri FROM locations WHERE source=?", arrayOf(source)).use { c ->
            while (c.moveToNext()) songOf[c.getString(0)] = Uri.parse(c.getString(1)).pathSegments.first()
        }
        val links = HashMap<String, Triple<String, String, String>>()
        readableDatabase.rawQuery("SELECT remote,local,server_hash,local_hash FROM remote_playlists WHERE source=?", arrayOf(source)).use { c ->
            while (c.moveToNext()) links[c.getString(0)] = Triple(c.getString(1), c.getString(2), c.getString(3))
        }
        val locals = HashMap<String, Pair<String, List<String>>>()
        val list = store.list()
        for (i in 0 until list.length()) {
            val p = list.getJSONObject(i)
            val ids = p.getJSONArray("ids")
            locals[p.getString("id")] = p.getString("name") to (0 until ids.length()).map { ids.getString(it) }
        }
        fun save(remote: String, local: String, serverHash: String, localHash: String) =
            writableDatabase.insertWithOnConflict(
                "remote_playlists", null,
                cv("source" to source, "remote" to remote, "local" to local, "server_hash" to serverHash, "local_hash" to localHash),
                SQLiteDatabase.CONFLICT_REPLACE,
            )
        val seen = HashSet<String>()
        for (p in server) {
            seen.add(p.id)
            val ids = p.songs.map { sha("mytify-remote-v1\u0000$source\u0000${it.id}".toByteArray()) }.filter { it in songOf }.distinct()
            val serverHash = fingerprint(p.name, ids)
            val link = links.remove(p.id)
            when {
                link == null -> {
                    val local = store.save(null, p.name.take(100).ifBlank { "Playlista" }, ids)
                    save(p.id, local, serverHash, fingerprint(p.name.take(100).ifBlank { "Playlista" }, ids))
                    result.imported++
                }
                link.first.isEmpty() -> save(p.id, "", serverHash, "")
                else -> {
                    val (local, oldServer, oldLocal) = link
                    val current = locals[local]
                    if (current == null) {
                        // Deleted here on purpose: stays deleted, the server copy is not touched.
                        save(p.id, "", serverHash, "")
                        continue
                    }
                    val localHash = fingerprint(current.first, current.second)
                    val serverChanged = serverHash != oldServer
                    val localChanged = localHash != oldLocal
                    when {
                        !serverChanged && !localChanged -> {}
                        serverChanged && !localChanged -> {
                            store.save(local, p.name.take(100).ifBlank { "Playlista" }, ids)
                            save(p.id, local, serverHash, fingerprint(p.name.take(100).ifBlank { "Playlista" }, ids))
                            result.updated++
                        }
                        !serverChanged && localChanged -> {
                            val sent = current.second.filter { it in songOf }
                            client.savePlaylist(p.id, current.first, sent.map { songOf[it]!! })
                            save(p.id, local, fingerprint(current.first, sent), localHash)
                            result.sent++
                        }
                        else -> {
                            val name = "${p.name} (z serwera)".take(100)
                            val copy = store.save(null, name, ids)
                            save(p.id, copy, serverHash, fingerprint(name, ids))
                            result.conflicts++
                        }
                    }
                }
            }
        }
        for (remote in links.keys) if (remote !in seen) writableDatabase.delete("remote_playlists", "source=? AND remote=?", arrayOf(source, remote))
        return result
    }

    private fun saveDav(existing: String?, config: JSONObject): String {
        val s = DavSettings.parse(config)
        val root = s.root().toString().lowercase()
        val id = existing ?: sha("webdav\u0000$root".toByteArray())
        val db = writableDatabase
        val previous =
            db.rawQuery("SELECT kind FROM sources WHERE id=?", arrayOf(id)).use {
                if (it.moveToFirst()) it.getString(0) else null
            }
        if (existing == null) require(previous == null) { "Ten folder WebDAV jest już dodany." }
        else require(previous == "webdav") { "Nie znaleziono źródła." }
        val old = sourceSettings(id)?.let { DavSettings.parse(it) }
        if (config.has("password") && !config.isNull("password"))
            Secrets.store(context, id, config.getString("password"))
        db.beginTransaction()
        try {
            if (previous == null)
                db.insertOrThrow(
                    "sources",
                    null,
                    cv("id" to id, "uri" to "dav://$id", "name" to s.name, "kind" to "webdav", "state" to "partial", "scanned" to 0),
                )
            else db.update("sources", cv("name" to s.name), "id=?", arrayOf(id))
            if (old != null && old.root() != s.root()) {
                // Another folder: old locations would only look like missing files.
                db.delete("locations", "source=?", arrayOf(id))
                db.update("sources", cv("state" to "partial", "scanned" to 0), "id=?", arrayOf(id))
            }
            db.insertWithOnConflict(
                "source_settings",
                null,
                cv("source" to id, "protocol" to "webdav", "settings" to s.json().toString()),
                SQLiteDatabase.CONFLICT_REPLACE,
            )
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        return id
    }

    fun saveSmb(existing: String?, config: JSONObject): String {
        val s = SmbSettings.parse(config)
        val root = "${s.host}\\${s.share}\\${s.folder}".lowercase()
        val id = existing ?: sha("smb\u0000$root".toByteArray())
        val db = writableDatabase
        val previous =
            db.rawQuery("SELECT kind FROM sources WHERE id=?", arrayOf(id)).use {
                if (it.moveToFirst()) it.getString(0) else null
            }
        if (existing == null) require(previous == null) { "Ten folder sieciowy jest już dodany." }
        else require(previous == "smb") { "Nie znaleziono źródła." }
        val old = sourceSettings(id)?.let { SmbSettings.parse(it) }
        if (config.has("password") && !config.isNull("password"))
            Secrets.store(context, id, config.getString("password"))
        db.beginTransaction()
        try {
            if (previous == null)
                db.insertOrThrow(
                    "sources",
                    null,
                    cv("id" to id, "uri" to "smb://$id", "name" to s.name, "kind" to "smb", "state" to "partial", "scanned" to 0),
                )
            else db.update("sources", cv("name" to s.name), "id=?", arrayOf(id))
            if (old != null && (old.host != s.host || old.share != s.share || old.folder != s.folder)) {
                // Another folder: old locations would only look like missing files. Tracks
                // (content hash), likes and playlists stay; the next scan links them again.
                db.delete("locations", "source=?", arrayOf(id))
                db.update("sources", cv("state" to "partial", "scanned" to 0), "id=?", arrayOf(id))
                Smb.close(id)
            }
            if (old != null && (old.user != s.user || old.domain != s.domain)) Smb.close(id)
            db.insertWithOnConflict(
                "source_settings",
                null,
                cv("source" to id, "protocol" to "smb", "settings" to s.json().toString()),
                SQLiteDatabase.CONFLICT_REPLACE,
            )
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        return id
    }

    private fun isAudio(name: String) = name.substringAfterLast('.').lowercase() in extensions

    /**
     * Stores one scanned file. Shared by phone folders and network shares, so a track has one
     * identity (content hash) whatever its location.
     */
    private fun record(
        source: String,
        u: String,
        name: String,
        hash: String,
        size: Long,
        modified: Long,
        old: String?,
        exists: Boolean,
        raw: JSONObject?,
    ): String {
        val db = writableDatabase
        db.beginTransaction()
        try {
            if (raw != null && !exists) {
                var patch = "{}"
                var liked = 0
                var added = System.currentTimeMillis()
                if (old != null)
                    db.rawQuery("SELECT patch,liked,added FROM tracks WHERE id=?", arrayOf(old)).use { c ->
                        if (c.moveToFirst()) {
                            patch = c.getString(0)
                            liked = c.getInt(1)
                            added = c.getLong(2)
                        }
                    }
                db.insertOrThrow(
                    "tracks",
                    null,
                    cv("id" to hash, "raw" to raw.toString(), "patch" to patch, "liked" to liked, "added" to added),
                )
            }
            db.insertWithOnConflict(
                "locations",
                null,
                cv(
                    "uri" to u,
                    "source" to source,
                    "track" to hash,
                    "name" to name,
                    "available" to 1,
                    "size" to size,
                    "modified" to modified,
                ),
                SQLiteDatabase.CONFLICT_REPLACE,
            )
            if (old != null && old != hash)
                db.execSQL(
                    "DELETE FROM tracks WHERE id=? AND id NOT IN (SELECT track FROM locations)",
                    arrayOf(old),
                )
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        return if (old == hash) "unchanged" else if (old != null) "updated" else if (exists) "duplicates" else "added"
    }

    private fun scanSmb(
        id: String,
        name: String,
        report: JSONObject,
        bump: (String) -> Unit,
        progress: (Int, Int, String) -> Unit,
    ) {
        val errors = report.getJSONArray("errors")
        val s = SmbSettings.parse(sourceSettings(id) ?: error("Brak ustawień źródła"))
        val password = Secrets.load(context, id) ?: ""
        progress(0, 0, "Łączenie z ${s.host}…")
        val entries =
            try {
                Smb.with(id, s, password) { share -> Smb.walk(share, s, ::isAudio) { cancelled.get() } }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Unreachable NAS: keep the collection, only the state changes.
                writableDatabase.update("sources", cv("state" to "offline"), "id=?", arrayOf(id))
                bump("offlineSources")
                errors.put("$name: ${Smb.friendly(e).message}")
                return
            }
        val seen = HashSet<String>()
        var complete = true
        for ((i, e) in entries.withIndex()) {
            checkCancel()
            val u = Smb.uri(id, e.path).toString()
            seen.add(u)
            progress(i, entries.size, e.name)
            try {
                if (readableDatabase.rawQuery("SELECT uri FROM ignored WHERE uri=?", arrayOf(u)).use { it.moveToFirst() }) {
                    bump("ignored")
                    continue
                }
                val prior =
                    readableDatabase
                        .rawQuery("SELECT track,size,modified FROM locations WHERE uri=? AND source=?", arrayOf(u, id))
                        .use { if (it.moveToFirst()) Triple(it.getString(0), it.getLong(1), it.getLong(2)) else null }
                if (prior != null && prior.second == e.size && prior.third == e.modified) {
                    // Same size and date: no need to read the whole file over the network again.
                    writableDatabase.update("locations", cv("available" to 1), "uri=? AND source=?", arrayOf(u, id))
                    bump("unchanged")
                    continue
                }
                val result =
                    Smb.with(id, s, password) { share ->
                        Smb.openFile(share, e.path).use { f ->
                            val digest = MessageDigest.getInstance("SHA-256")
                            val buffer = ByteArray(1024 * 1024)
                            var offset = 0L
                            while (true) {
                                checkCancel()
                                val n = f.read(buffer, offset, 0, buffer.size)
                                if (n <= 0) break
                                digest.update(buffer, 0, n)
                                offset += n
                            }
                            require(offset == e.size) { "Plik zmienił się podczas skanowania. Spróbuj ponownie." }
                            val hash = digest.digest().joinToString("") { "%02x".format(it) }
                            val exists =
                                readableDatabase.rawQuery("SELECT id FROM tracks WHERE id=?", arrayOf(hash)).use {
                                    it.moveToFirst()
                                }
                            val raw =
                                if (!exists) readTags(Doc(Uri.parse(u), e.name, e.size), SmbMediaDataSource(f, e.size))
                                else null
                            Triple(hash, exists, raw)
                        }
                    }
                bump(record(id, u, e.name, result.first, e.size, e.modified, prior?.first, result.second, result.third))
            } catch (x: CancellationException) {
                throw x
            } catch (x: Exception) {
                complete = false
                if (errors.length() < 100) errors.put("${e.name}: ${Smb.friendly(x).message}")
            }
        }
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.rawQuery("SELECT uri,available FROM locations WHERE source=?", arrayOf(id)).use { c ->
                while (c.moveToNext()) if (c.getString(0) !in seen) {
                    if (c.getInt(1) > 0) bump("missing")
                    db.update("locations", cv("available" to 0), "source=? AND uri=?", arrayOf(id, c.getString(0)))
                }
            }
            db.update(
                "sources",
                cv("state" to if (complete) "online" else "partial", "scanned" to System.currentTimeMillis()),
                "id=?",
                arrayOf(id),
            )
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        progress(entries.size, entries.size, "Gotowe")
    }

    /**
     * WebDAV tracks get a stable id from source and server path (same rule as on the PC):
     * hashing every file over the internet would be too costly. Tags come through ranges.
     */
    private fun scanDav(
        id: String,
        name: String,
        report: JSONObject,
        bump: (String) -> Unit,
        progress: (Int, Int, String) -> Unit,
    ) {
        val errors = report.getJSONArray("errors")
        val s = DavSettings.parse(sourceSettings(id) ?: error("Brak ustawień źródła"))
        val password = Secrets.load(context, id) ?: ""
        progress(0, 0, "Łączenie z $name…")
        val files = mutableListOf<WebDav.Entry>()
        val todo = ArrayDeque<okhttp3.HttpUrl>().apply { add(s.root()) }
        var complete = true
        while (todo.isNotEmpty()) {
            checkCancel()
            val folder = todo.removeLast()
            val entries =
                try {
                    WebDav.list(s, password, folder)
                } catch (e: Exception) {
                    if (folder == s.root()) {
                        writableDatabase.update("sources", cv("state" to "offline"), "id=?", arrayOf(id))
                        bump("offlineSources")
                        errors.put("$name: ${WebDav.friendly(e).message}")
                        return
                    }
                    complete = false
                    if (errors.length() < 100) errors.put("${Uri.decode(folder.encodedPath)}: ${WebDav.friendly(e).message}")
                    continue
                }
            for (e in entries) {
                if (e.dir) {
                    if (!e.name.startsWith('.') && !e.name.startsWith('#') && e.name != "@eaDir")
                        todo.add(folder.resolve(if (e.href.endsWith("/")) e.href else e.href + "/")!!)
                } else if (isAudio(e.name)) files.add(e) else bump("ignored")
            }
            require(files.size <= 200000) { "Wybierz mniejszy folder" }
            progress(0, 0, "Przeglądam $name… (${files.size} plików)")
        }
        files.sortBy { it.href }
        val seen = HashSet<String>()
        for ((i, e) in files.withIndex()) {
            checkCancel()
            val u = WebDav.uri(id, e.href).toString()
            seen.add(u)
            progress(i, files.size, e.name)
            try {
                if (readableDatabase.rawQuery("SELECT uri FROM ignored WHERE uri=?", arrayOf(u)).use { it.moveToFirst() }) {
                    bump("ignored")
                    continue
                }
                val version = e.version.hashCode().toLong()
                val prior =
                    readableDatabase
                        .rawQuery("SELECT track,size,modified FROM locations WHERE uri=? AND source=?", arrayOf(u, id))
                        .use { if (it.moveToFirst()) Triple(it.getString(0), it.getLong(1), it.getLong(2)) else null }
                if (prior != null && prior.second == e.size && prior.third == version && e.version.isNotEmpty()) {
                    writableDatabase.update("locations", cv("available" to 1), "uri=? AND source=?", arrayOf(u, id))
                    bump("unchanged")
                    continue
                }
                val track = sha("mytify-remote-v1\u0000$id\u0000${e.href}".toByteArray())
                val cache = File(context.cacheDir, "dav-tags-${System.nanoTime()}")
                val raw =
                    DavMediaDataSource(s, password, WebDav.https(s, Uri.parse(u)), e.size, cache).use { src ->
                        readTags(Doc(Uri.parse(u), Uri.decode(e.name), e.size), src)
                    }
                val exists =
                    readableDatabase.rawQuery("SELECT id FROM tracks WHERE id=?", arrayOf(track)).use { it.moveToFirst() }
                if (exists) {
                    // Same place, new file version: fresh tags, likes and manual edits stay.
                    writableDatabase.update("tracks", cv("raw" to raw.toString()), "id=?", arrayOf(track))
                }
                bump(record(id, u, Uri.decode(e.name), track, e.size, version, prior?.first, exists, raw).let {
                    if (it == "unchanged" && prior != null) "updated" else it
                })
            } catch (x: CancellationException) {
                throw x
            } catch (x: Exception) {
                complete = false
                if (errors.length() < 100) errors.put("${Uri.decode(e.name)}: ${WebDav.friendly(x).message}")
            }
        }
        val db = writableDatabase
        db.beginTransaction()
        try {
            if (complete)
                db.rawQuery("SELECT uri,available FROM locations WHERE source=?", arrayOf(id)).use { c ->
                    while (c.moveToNext()) if (c.getString(0) !in seen) {
                        if (c.getInt(1) > 0) bump("missing")
                        db.update("locations", cv("available" to 0), "source=? AND uri=?", arrayOf(id, c.getString(0)))
                    }
                }
            db.update(
                "sources",
                cv("state" to if (complete) "online" else "partial", "scanned" to System.currentTimeMillis()),
                "id=?",
                arrayOf(id),
            )
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        progress(files.size, files.size, "Gotowe")
    }

    fun scan(
        sourceId: String?,
        explicit: Boolean = false,
        progress: (Int, Int, String) -> Unit,
    ): JSONObject {
        val report =
            obj(
                "added" to 0,
                "duplicates" to 0,
                "ignored" to 0,
                "updated" to 0,
                "unchanged" to 0,
                "missing" to 0,
                "offlineSources" to 0,
                "errors" to JSONArray(),
                "cancelled" to false,
            )
        fun bump(k: String) {
            report.put(k, report.getInt(k) + 1)
        }
        val sources = sourceList()
        try {
            for (s in 0 until sources.length()) {
                checkCancel()
                val source = sources.getJSONObject(s)
                val id = source.getString("id")
                if (sourceId != null && sourceId != id) continue
                // Offline copies are written and verified by Downloads, never scanned.
                if (source.getString("kind") == "downloads") continue
                val root =
                    readableDatabase
                        .rawQuery("SELECT uri FROM sources WHERE id=?", arrayOf(id))
                        .use {
                            it.moveToFirst()
                            it.getString(0)
                        }
                if (source.getString("kind") == "smb") {
                    scanSmb(id, source.getString("name"), report, ::bump, progress)
                    continue
                }
                if (source.getString("kind") == "webdav") {
                    scanDav(id, source.getString("name"), report, ::bump, progress)
                    continue
                }
                if (source.getString("kind") == "subsonic") {
                    scanServer(id, source.getString("name"), report, ::bump, progress)
                    continue
                }
                writableDatabase.update("sources", cv("state" to "partial"), "id=?", arrayOf(id))
                val docs: List<Doc>
                try {
                    progress(0, 0, "Przeglądam ${source.getString("name")}…")
                    docs =
                        if (source.getString("kind") == "folder") enumerate(Uri.parse(root))
                        else
                            JSONArray(root)
                                .strings()
                                .mapNotNull { u ->
                                    try {
                                        document(Uri.parse(u))
                                    } catch (e: Exception) {
                                        if (report.getJSONArray("errors").length() < 100)
                                            report.getJSONArray("errors").put("Brak dostępu: $u")
                                        null
                                    }
                                }
                                .also { check(it.isNotEmpty()) { "Źródło jest niedostępne" } }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    writableDatabase.update(
                        "sources",
                        cv("state" to "offline"),
                        "id=?",
                        arrayOf(id),
                    )
                    writableDatabase.update(
                        "locations",
                        cv("available" to 0),
                        "source=?",
                        arrayOf(id),
                    )
                    bump("offlineSources")
                    report
                        .getJSONArray("errors")
                        .put("${source.getString("name")}: brak dostępu. Wskaż źródło ponownie.")
                    continue
                }
                val seen = HashSet<String>()
                for ((i, d) in docs.withIndex()) {
                    checkCancel()
                    val u = d.uri.toString()
                    seen.add(u)
                    progress(i, docs.size, d.name)
                    try {
                        if (explicit && source.getString("kind") == "files")
                            writableDatabase.delete("ignored", "uri=?", arrayOf(u))
                        if (
                            readableDatabase
                                .rawQuery("SELECT uri FROM ignored WHERE uri=?", arrayOf(u))
                                .use { it.moveToFirst() }
                        ) {
                            bump("ignored")
                            continue
                        }
                        val digest = MessageDigest.getInstance("SHA-256")
                        var size = 0L
                        (resolver.openInputStream(d.uri) ?: error("Nie można otworzyć pliku"))
                            .use { input ->
                                val buffer = ByteArray(128 * 1024)
                                while (true) {
                                    checkCancel()
                                    val n = input.read(buffer)
                                    if (n < 0) break
                                    digest.update(buffer, 0, n)
                                    size += n
                                }
                            }
                        val hash = digest.digest().joinToString("") { "%02x".format(it) }
                        val old =
                            readableDatabase
                                .rawQuery(
                                    "SELECT track FROM locations WHERE uri=? AND source=?",
                                    arrayOf(u, id),
                                )
                                .use { if (it.moveToFirst()) it.getString(0) else null }
                        val exists =
                            readableDatabase
                                .rawQuery("SELECT id FROM tracks WHERE id=?", arrayOf(hash))
                                .use { it.moveToFirst() }
                        val raw = if (!exists) readTags(d.copy(size = size)) else null
                        val db = writableDatabase
                        db.beginTransaction()
                        try {
                            if (raw != null) {
                                var patch = "{}"
                                var liked = 0
                                var added = System.currentTimeMillis()
                                if (old != null)
                                    db.rawQuery(
                                            "SELECT patch,liked,added FROM tracks WHERE id=?",
                                            arrayOf(old),
                                        )
                                        .use { c ->
                                            if (c.moveToFirst()) {
                                                patch = c.getString(0)
                                                liked = c.getInt(1)
                                                added = c.getLong(2)
                                            }
                                        }
                                db.insertOrThrow(
                                    "tracks",
                                    null,
                                    cv(
                                        "id" to hash,
                                        "raw" to raw.toString(),
                                        "patch" to patch,
                                        "liked" to liked,
                                        "added" to added,
                                    ),
                                )
                            }
                            db.insertWithOnConflict(
                                "locations",
                                null,
                                cv(
                                    "uri" to u,
                                    "source" to id,
                                    "track" to hash,
                                    "name" to d.name,
                                    "available" to 1,
                                ),
                                SQLiteDatabase.CONFLICT_REPLACE,
                            )
                            if (old != null && old != hash)
                                db.execSQL(
                                    "DELETE FROM tracks WHERE id=? AND id NOT IN (SELECT track FROM locations)",
                                    arrayOf(old),
                                )
                            db.setTransactionSuccessful()
                        } finally {
                            db.endTransaction()
                        }
                        bump(
                            if (old == hash) "unchanged"
                            else if (old != null) "updated"
                            else if (exists) "duplicates" else "added"
                        )
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        if (report.getJSONArray("errors").length() < 100)
                            report
                                .getJSONArray("errors")
                                .put("${d.name}: ${e.message?:"błąd odczytu"}")
                        writableDatabase.update(
                            "locations",
                            cv("available" to 0),
                            "source=? AND uri=?",
                            arrayOf(id, u),
                        )
                    }
                }
                val db = writableDatabase
                db.beginTransaction()
                try {
                    db.rawQuery("SELECT uri,available FROM locations WHERE source=?", arrayOf(id))
                        .use { c ->
                            while (c.moveToNext()) if (c.getString(0) !in seen) {
                                if (c.getInt(1) > 0) bump("missing")
                                db.update(
                                    "locations",
                                    cv("available" to 0),
                                    "source=? AND uri=?",
                                    arrayOf(id, c.getString(0)),
                                )
                            }
                        }
                    db.update(
                        "sources",
                        cv("state" to "online", "scanned" to System.currentTimeMillis()),
                        "id=?",
                        arrayOf(id),
                    )
                    db.setTransactionSuccessful()
                } finally {
                    db.endTransaction()
                }
                progress(docs.size, docs.size, "Gotowe")
            }
        } catch (e: CancellationException) {
            report.put("cancelled", true)
        }
        return report
    }

    private fun ownership(): JSONObject {
        val f = AtomicFile(File(context.filesDir, "offline-owned.json"))
        return if (f.baseFile.exists())
            JSONObject(f.openRead().use { it.readBytes().toString(Charsets.UTF_8) })
        else JSONObject()
    }

    private fun saveOwnership(j: JSONObject) {
        val f = AtomicFile(File(context.filesDir, "offline-owned.json"))
        val out = f.startWrite()
        try {
            out.write(j.toString().toByteArray())
            f.finishWrite(out)
        } catch (e: Exception) {
            f.failWrite(out)
            throw e
        }
    }

    private fun rememberOffline(peer: String, uri: String) {
        synchronized(offlineOwnershipLock) {
            val j = ownership()
            val set = j.optJSONArray(peer)?.strings()?.toMutableSet() ?: mutableSetOf()
            if (set.add(uri)) {
                j.put(peer, JSONArray(set.toList()))
                saveOwnership(j)
            }
        }
    }

    internal fun registerOffline(
        peer: String,
        name: String,
        item: JSONObject,
        file: File,
        cover: String?,
    ) {
        require(transferId(peer) && transferId(item.getString("id")))
        require(
            file.canonicalFile.parentFile ==
                File(context.filesDir, "offline-music").canonicalFile && file.isFile
        )
        val hash = item.getString("id")
        val source = "offline:$peer"
        val uri = Uri.fromFile(file).toString()
        val raw =
            obj(
                "title" to item.optString("title").take(512),
                "artist" to item.optString("artist").take(512),
                "album" to item.optString("album").take(512),
                "albumArtist" to item.optString("albumArtist").take(512),
                "fileName" to item.optString("fileName").take(256),
                "format" to item.optString("format").take(24),
                "size" to file.length(),
                "durationMs" to item.optLong("durationMs").coerceAtLeast(0),
                "sampleRate" to item.optInt("sampleRate").coerceAtLeast(0),
                "bitDepth" to item.optInt("bitDepth").coerceIn(0, 64),
                "trackNumber" to item.optInt("trackNumber").coerceIn(0, 9999),
                "discNumber" to item.optInt("discNumber").coerceIn(0, 9999),
                "managed" to true,
                "cover" to (cover ?: ""),
                "metadataSource" to "PC",
            )
        val base =
            readTags(Doc(Uri.fromFile(file), item.optString("fileName", file.name), file.length()))
                .put("managed", true)
        for (k in listOf("sampleRate", "bitDepth", "durationMs")) base.put(k, raw.get(k))
        val patch = obj("metadataSource" to "PC")
        for (k in
            listOf(
                "title",
                "artist",
                "album",
                "albumArtist",
                "trackNumber",
                "discNumber",
                "cover",
            )) patch.put(k, raw.get(k))
        rememberOffline(peer, uri)
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.insertWithOnConflict(
                "tracks",
                null,
                cv(
                    "id" to hash,
                    "raw" to base.toString(),
                    "patch" to patch.toString(),
                    "liked" to if (item.optBoolean("liked")) 1 else 0,
                    "added" to System.currentTimeMillis(),
                ),
                SQLiteDatabase.CONFLICT_IGNORE,
            )
            db.insertWithOnConflict(
                "locations",
                null,
                cv(
                    "uri" to uri,
                    "source" to source,
                    "track" to hash,
                    "name" to file.name,
                    "available" to 1,
                ),
                SQLiteDatabase.CONFLICT_REPLACE,
            )
            val uris = mutableListOf<String>()
            db.rawQuery("SELECT uri FROM locations WHERE source=?", arrayOf(source)).use { c ->
                while (c.moveToNext()) uris.add(c.getString(0))
            }
            db.insertWithOnConflict(
                "sources",
                null,
                cv(
                    "id" to source,
                    "uri" to JSONArray(uris).toString(),
                    "name" to "Offline · $name",
                    "kind" to "offline",
                    "state" to "online",
                    "scanned" to System.currentTimeMillis(),
                ),
                SQLiteDatabase.CONFLICT_REPLACE,
            )
            db.delete("ignored", "uri=?", arrayOf(uri))
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    internal fun importOfflinePlaylist(id: String, name: String, ids: List<String>) {
        val db = writableDatabase
        if (
            db.rawQuery("SELECT id FROM playlists WHERE id=?", arrayOf(id)).use { it.moveToFirst() }
        )
            return
        db.beginTransaction()
        try {
            db.insertOrThrow("playlists", null, cv("id" to id, "name" to name.take(100)))
            ids.distinct().forEachIndexed { n, t ->
                require(
                    db.rawQuery("SELECT id FROM tracks WHERE id=?", arrayOf(t)).use {
                        it.moveToFirst()
                    }
                )
                db.insertOrThrow(
                    "playlist_tracks",
                    null,
                    cv("playlist" to id, "track" to t, "position" to n),
                )
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    internal fun deleteOffline(peer: String) {
        require(transferId(peer))
        val id = "offline:$peer"
        val uris = mutableListOf<String>()
        readableDatabase.rawQuery("SELECT uri FROM locations WHERE source=?", arrayOf(id)).use { c
            ->
            while (c.moveToNext()) uris.add(c.getString(0))
        }
        synchronized(offlineOwnershipLock) {
            val owned = ownership()
            uris.addAll(owned.optJSONArray(peer)?.strings() ?: emptyList())
            forget(id)
            owned.remove(peer)
            saveOwnership(owned)
            val retained =
                owned
                    .keys()
                    .asSequence()
                    .flatMap { owned.getJSONArray(it).strings().asSequence() }
                    .toSet()
            uris.removeAll(retained)
        }
        for (u in uris.distinct()) {
            if (
                readableDatabase.rawQuery("SELECT uri FROM locations WHERE uri=?", arrayOf(u)).use {
                    it.moveToFirst()
                }
            )
                continue
            val uri = Uri.parse(u)
            if (uri.scheme != "file") continue
            val f = File(uri.path!!).canonicalFile
            if (f.parentFile == File(context.filesDir, "offline-music").canonicalFile) f.delete()
        }
    }

    private fun readTags(d: Doc, source: android.media.MediaDataSource? = null): JSONObject {
        val raw =
            obj(
                "title" to d.name.substringBeforeLast('.'),
                "artist" to "",
                "album" to "",
                "albumArtist" to "",
                "fileName" to d.name,
                "format" to d.name.substringAfterLast('.').uppercase(),
                "size" to d.size,
                "durationMs" to 0,
                "trackNumber" to 0,
                "discNumber" to 0,
                "sampleRate" to 0,
                "bitDepth" to 0,
                "managed" to false,
                "metadataSource" to "",
                "cover" to "",
            )
        val r = MediaMetadataRetriever()
        try {
            if (source != null) r.setDataSource(source) else r.setDataSource(context, d.uri)
            listOf(
                    "title" to MediaMetadataRetriever.METADATA_KEY_TITLE,
                    "artist" to MediaMetadataRetriever.METADATA_KEY_ARTIST,
                    "album" to MediaMetadataRetriever.METADATA_KEY_ALBUM,
                    "albumArtist" to MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST,
                )
                .forEach { (k, v) ->
                    r.extractMetadata(v)?.takeIf { it.isNotBlank() }?.let { raw.put(k, it) }
                }
            listOf(
                    "durationMs" to MediaMetadataRetriever.METADATA_KEY_DURATION,
                    "trackNumber" to MediaMetadataRetriever.METADATA_KEY_CD_TRACK_NUMBER,
                    "discNumber" to MediaMetadataRetriever.METADATA_KEY_DISC_NUMBER,
                    "sampleRate" to MediaMetadataRetriever.METADATA_KEY_SAMPLERATE,
                    "bitDepth" to MediaMetadataRetriever.METADATA_KEY_BITS_PER_SAMPLE,
                )
                .forEach { (k, v) ->
                    raw.put(k, r.extractMetadata(v)?.substringBefore('/')?.toLongOrNull() ?: 0)
                }
            r.embeddedPicture
                ?.takeIf { it.size <= 8 * 1024 * 1024 }
                ?.let { bytes ->
                    runCatching { raw.put("cover", storeCover(bytes).getString("hash")) }
                }
        } catch (_: Exception) {
            /* Unsupported tags keep filename fallback. */
        } finally {
            r.release()
        }
        return raw
    }
}
