package pl.mytify.mytify

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.IBinder
import android.os.PowerManager
import android.os.StatFs
import android.os.SystemClock
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject

/**
 * Offline copies of network tracks. A download is another location of the same track
 * (never a second track or album), lives in app storage that the system does not clean,
 * is verified before it becomes playable, and removing it keeps the NAS file, likes and
 * playlists. Partial files of another source version are never continued.
 */
class Downloads(private val context: Context, private val catalog: Catalog) {
    companion object {
        const val SOURCE = "offline:downloads"

        /** Unit tests run without a real network stack. */
        @Volatile internal var assumeNetwork: Boolean? = null
        private const val MARGIN = 200L * 1024 * 1024
        private const val MAX_ATTEMPTS = 5

        fun create(db: SQLiteDatabase) {
            db.execSQL("CREATE TABLE IF NOT EXISTS downloads(track TEXT PRIMARY KEY,state TEXT NOT NULL,done INTEGER NOT NULL DEFAULT 0,total INTEGER NOT NULL DEFAULT 0,version TEXT NOT NULL DEFAULT '',error TEXT NOT NULL DEFAULT '',reason TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,added INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE IF NOT EXISTS kept_playlists(playlist TEXT PRIMARY KEY)")
        }

        /** Starts the background worker when there is something to do and the network allows it. */
        fun kick(context: Context) {
            val d = Downloads(context, NetworkSources.catalogOf(context))
            if (d.paused || !d.networkAllowed() || d.next() == null) return
            runCatching { context.startForegroundService(Intent(context, DownloadService::class.java)) }
        }
    }

    val dir = File(context.filesDir, "downloads").apply { mkdirs() }

    /** Stops the worker without changing the user's pause choice (system time limits). */
    @Volatile var stop = false
    private val prefs = context.getSharedPreferences("downloads", Context.MODE_PRIVATE)

    var paused: Boolean
        get() = prefs.getBoolean("paused", false)
        set(v) {
            prefs.edit().putBoolean("paused", v).apply()
        }

    /** Mobile data is used only when the user allows it. */
    var cellular: Boolean
        get() = prefs.getBoolean("cellular", false)
        set(v) {
            prefs.edit().putBoolean("cellular", v).apply()
        }

    init {
        catalog.writableDatabase.insertWithOnConflict(
            "sources",
            null,
            cv("id" to SOURCE, "uri" to Uri.fromFile(dir).toString(), "name" to "Pobrane", "kind" to "downloads", "state" to "online", "scanned" to 0),
            SQLiteDatabase.CONFLICT_IGNORE,
        )
    }

    fun networkAllowed(): Boolean {
        assumeNetwork?.let { return it }
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return false
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return false
        return cellular || caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }

    fun free(): Long = StatFs(dir.path).availableBytes

    fun next(): String? =
        catalog.readableDatabase.rawQuery("SELECT track FROM downloads WHERE state='queued' ORDER BY added,track LIMIT 1", null).use {
            if (it.moveToFirst()) it.getString(0) else null
        }

    private fun info(id: String): Triple<Boolean, Boolean, Long> =
        catalog.readableDatabase
            .rawQuery(
                "SELECT MAX(CASE WHEN source LIKE 'offline:%' AND available=1 THEN 1 ELSE 0 END),MAX(CASE WHEN uri LIKE 'smb:%' OR uri LIKE 'dav:%' OR uri LIKE 'subsonic:%' THEN 1 ELSE 0 END),MAX(size) FROM locations WHERE track=?",
                arrayOf(id),
            )
            .use { if (it.moveToFirst()) Triple(it.getInt(0) > 0, it.getInt(1) > 0, it.getLong(2)) else Triple(false, false, 0L) }

    fun estimate(ids: List<String>): JSONObject {
        var count = 0
        var bytes = 0L
        var unknown = 0
        for (id in ids) {
            val (offline, remote, size) = info(id)
            if (!remote || offline) continue
            count++
            if (size > 0) bytes += size else unknown++
        }
        return obj("count" to count, "bytes" to bytes, "unknown" to unknown, "free" to free())
    }

    fun add(ids: List<String>, reason: String): Int {
        var added = 0
        val db = catalog.writableDatabase
        for (id in ids) {
            val (offline, remote, _) = info(id)
            if (offline && reason == "user") {
                // Already here because of a kept playlist: now the user's own choice too.
                db.execSQL("UPDATE downloads SET reason='user' WHERE track=?", arrayOf(id))
                continue
            }
            if (!remote || offline) continue
            db.execSQL(
                "INSERT INTO downloads(track,state,reason,added) VALUES(?,'queued',?,?) ON CONFLICT(track) DO UPDATE SET reason=CASE WHEN excluded.reason='user' THEN 'user' ELSE reason END,state=CASE WHEN state='failed' THEN 'queued' ELSE state END,attempts=CASE WHEN state='failed' THEN 0 ELSE attempts END",
                arrayOf(id, reason, System.currentTimeMillis()),
            )
            added++
        }
        kick(context)
        return added
    }

    fun status(): JSONObject {
        val items = JSONArray()
        catalog.readableDatabase
            .rawQuery("SELECT d.track,d.state,d.done,d.total,d.error,d.reason,t.raw FROM downloads d LEFT JOIN tracks t ON t.id=d.track WHERE d.state<>'done' ORDER BY d.added,d.track", null)
            .use { c ->
                while (c.moveToNext()) {
                    val raw = c.getString(6)?.let { JSONObject(it) } ?: JSONObject()
                    items.put(
                        obj(
                            "id" to c.getString(0), "state" to c.getString(1), "done" to c.getLong(2), "total" to c.getLong(3),
                            "error" to c.getString(4), "reason" to c.getString(5),
                            "title" to raw.optString("title"), "artist" to raw.optString("artist"),
                        )
                    )
                }
            }
        val used =
            catalog.readableDatabase.rawQuery("SELECT COALESCE(SUM(size),0) FROM locations WHERE source=? AND available=1", arrayOf(SOURCE)).use {
                it.moveToFirst()
                it.getLong(0)
            }
        val kept = JSONArray()
        catalog.readableDatabase.rawQuery("SELECT playlist FROM kept_playlists", null).use { c -> while (c.moveToNext()) kept.put(c.getString(0)) }
        return obj("items" to items, "paused" to paused, "used" to used, "free" to free(), "kept" to kept, "cellular" to cellular)
    }

    fun pause(value: Boolean) {
        paused = value
        if (!value) kick(context)
    }

    fun cancel(ids: List<String>) {
        for (id in ids) {
            catalog.writableDatabase.delete("downloads", "track=? AND state<>'done'", arrayOf(id))
            dir.listFiles { f -> f.name.startsWith(id) && (f.name.endsWith(".part") || f.name.endsWith(".part.json")) }?.forEach { it.delete() }
        }
    }

    /** "Usuń pobranie": only the local copy goes. */
    fun remove(ids: List<String>) {
        cancel(ids)
        val db = catalog.writableDatabase
        for (id in ids) {
            db.rawQuery("SELECT uri FROM locations WHERE source=? AND track=?", arrayOf(SOURCE, id)).use { c ->
                while (c.moveToNext()) {
                    val f = Uri.parse(c.getString(0)).path?.let(::File)
                    // Only files inside our own folder are ever deleted.
                    if (f != null && f.canonicalPath.startsWith(dir.canonicalPath)) f.delete()
                }
            }
            db.delete("locations", "source=? AND track=?", arrayOf(SOURCE, id))
            db.delete("downloads", "track=?", arrayOf(id))
        }
        LibraryChanges.changed()
    }

    fun keep(playlist: String, keep: Boolean) {
        if (keep) {
            catalog.writableDatabase.insertWithOnConflict("kept_playlists", null, cv("playlist" to playlist), SQLiteDatabase.CONFLICT_IGNORE)
            add(PlaylistStore(catalog).ids(playlist), "playlist:$playlist")
        } else {
            catalog.writableDatabase.delete("kept_playlists", "playlist=?", arrayOf(playlist))
            // Copies only this playlist wanted go; user downloads stay.
            val only =
                catalog.readableDatabase.rawQuery("SELECT track FROM downloads WHERE reason=?", arrayOf("playlist:$playlist")).use { c ->
                    buildList { while (c.moveToNext()) add(c.getString(0)) }
                }
            remove(only)
        }
    }

    /** New entries of kept playlists are queued (after edits, syncs and reconnects). */
    fun refreshKept() {
        catalog.readableDatabase.rawQuery("SELECT playlist FROM kept_playlists", null).use { c ->
            buildList { while (c.moveToNext()) add(c.getString(0)) }
        }.forEach { add(PlaylistStore(catalog).ids(it), "playlist:$it") }
    }

    private fun set(id: String, state: String, error: String) =
        catalog.writableDatabase.update("downloads", cv("state" to state, "error" to error), "track=?", arrayOf(id))

    /** Runs the queue until it is empty, paused or the network no longer allows it. */
    fun runQueue(progress: () -> Unit) {
        catalog.writableDatabase.execSQL("UPDATE downloads SET state='queued' WHERE state='running'")
        while (!paused && !stop && networkAllowed()) {
            val id = next() ?: break
            set(id, "running", "")
            progress()
            try {
                fetch(id, progress)
            } catch (e: Exception) {
                val message = (e as? SourceException)?.message ?: Smb.friendly(e).message ?: "Pobieranie nie powiodło się."
                if (message == "Pobieranie wstrzymane." || message == "Anulowano.") {
                    if (message.startsWith("Pobieranie")) set(id, "queued", "")
                    continue
                }
                catalog.writableDatabase.execSQL("UPDATE downloads SET attempts=attempts+1 WHERE track=?", arrayOf(id))
                val attempts =
                    catalog.readableDatabase.rawQuery("SELECT attempts FROM downloads WHERE track=?", arrayOf(id)).use {
                        if (it.moveToFirst()) it.getInt(0) else MAX_ATTEMPTS
                    }
                val final = message.startsWith("Brak miejsca") || attempts >= MAX_ATTEMPTS
                set(id, if (final) "failed" else "queued", message)
                if (!final) Thread.sleep(5000)
            }
            progress()
        }
    }

    private fun fetch(id: String, progress: () -> Unit) {
        if (!catalog.readableDatabase.rawQuery("SELECT track FROM downloads WHERE track=?", arrayOf(id)).use { it.moveToFirst() }) return
        val (uri, size, version, name) =
            catalog.readableDatabase
                .rawQuery(
                    "SELECT uri,size,modified,name FROM locations WHERE track=? AND (uri LIKE 'smb:%' OR uri LIKE 'dav:%' OR uri LIKE 'subsonic:%') ORDER BY available DESC,CASE WHEN uri LIKE 'smb:%' THEN 0 WHEN uri LIKE 'subsonic:%' THEN 1 ELSE 2 END LIMIT 1",
                    arrayOf(id),
                )
                .use {
                    if (!it.moveToFirst()) throw SourceException("Utwór nie ma już źródła sieciowego.")
                    listOf(it.getString(0), it.getLong(1).toString(), it.getLong(2).toString(), it.getString(3))
                }
        val location = Uri.parse(uri)
        val total = size.toLong()
        val ext = name.substringAfterLast('.', "").lowercase().takeIf { it.length in 1..8 && it.all(Char::isLetterOrDigit) }?.let { ".$it" } ?: ""
        val target = File(dir, "$id$ext")
        val partial = File(dir, "$id$ext.part")
        val marker = File(dir, "$id$ext.part.json")
        // Never continue a partial file of another version of the source file.
        val resumable = partial.isFile && marker.isFile && marker.readText() == version
        if (!resumable) {
            partial.delete()
            marker.writeText(version)
        }
        var start = if (resumable) partial.length() else 0L
        if (total > 0 && free() < total - start + MARGIN) throw SourceException("Brak miejsca w pamięci telefonu.")
        catalog.writableDatabase.update("downloads", cv("total" to total, "done" to start, "version" to version), "track=?", arrayOf(id))
        val input: InputStream =
            when (location.scheme) {
                "subsonic" -> {
                    // The download API always gives the original file, never a conversion.
                    val source = location.authority!!
                    val url = catalog.server(source).url("download", listOf("id" to location.pathSegments.first()))
                    val r = WebDav.client.newCall(Request.Builder().url(url).header("Range", "bytes=$start-").build()).execute()
                    if (!r.isSuccessful) {
                        r.close()
                        throw SourceException("Serwer nie udostępnił pliku.")
                    }
                    if (r.code != 206 && start > 0) {
                        partial.delete()
                        start = 0
                    }
                    r.body!!.byteStream()
                }
                "dav" -> {
                    val source = location.authority!!
                    val s = NetworkSources.dav(context, source)
                    val (r, ranged) = WebDav.read(s, Secrets.load(context, source) ?: "", WebDav.https(s, location), start, maxOf(1, total - start))
                    if (!ranged && start > 0) {
                        partial.delete()
                        start = 0
                    }
                    r.body!!.byteStream()
                }
                else -> NetworkSources.stream(context, location, start)
            }
        input.use { stream ->
            FileOutputStream(partial, true).use { out ->
                val buffer = ByteArray(256 * 1024)
                var done = start
                var last = 0L
                while (true) {
                    if (paused || stop) throw SourceException("Pobieranie wstrzymane.")
                    val n = stream.read(buffer)
                    if (n < 0) break
                    try {
                        out.write(buffer, 0, n)
                    } catch (e: java.io.IOException) {
                        if (free() < MARGIN) throw SourceException("Brak miejsca w pamięci telefonu.")
                        throw e
                    }
                    done += n
                    val now = SystemClock.elapsedRealtime()
                    if (now - last > 500) {
                        last = now
                        if (catalog.writableDatabase.update("downloads", cv("done" to done), "track=?", arrayOf(id)) == 0)
                            throw SourceException("Anulowano.")
                        progress()
                    }
                }
                out.fd.sync()
            }
        }
        if (!catalog.readableDatabase.rawQuery("SELECT track FROM downloads WHERE track=?", arrayOf(id)).use { it.moveToFirst() }) {
            partial.delete()
            marker.delete()
            return
        }
        // Completeness: content-hash tracks (SMB) must match their id; others their size.
        val ok =
            if (location.scheme == "smb") {
                val digest = MessageDigest.getInstance("SHA-256")
                partial.inputStream().use { s ->
                    val b = ByteArray(1024 * 1024)
                    while (true) {
                        val n = s.read(b)
                        if (n < 0) break
                        digest.update(b, 0, n)
                    }
                }
                digest.digest().joinToString("") { "%02x".format(it) } == id
            } else total <= 0 || partial.length() == total
        if (!ok) {
            partial.delete()
            marker.delete()
            throw SourceException("Pobrany plik jest niekompletny albo zmienił się na serwerze. Pobieranie zacznie się od nowa.")
        }
        check(partial.renameTo(target)) { "Nie można zapisać pobranego pliku" }
        marker.delete()
        val db = catalog.writableDatabase
        db.beginTransaction()
        try {
            db.insertWithOnConflict(
                "locations",
                null,
                cv("uri" to Uri.fromFile(target).toString(), "source" to SOURCE, "track" to id, "name" to name, "available" to 1, "size" to target.length(), "modified" to version.toLong()),
                SQLiteDatabase.CONFLICT_REPLACE,
            )
            db.update("downloads", cv("state" to "done", "done" to target.length(), "total" to target.length(), "error" to ""), "track=?", arrayOf(id))
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        LibraryChanges.changed()
    }
}

/** Foreground work with a progress notification, as Android requires for long transfers. */
class DownloadService : Service() {
    private val executor = Executors.newSingleThreadExecutor()
    private val started = AtomicBoolean(false)
    private var wake: PowerManager.WakeLock? = null
    private var last = 0L
    private lateinit var downloads: Downloads

    override fun onCreate() {
        super.onCreate()
        downloads = Downloads(this, NetworkSources.catalogOf(this))
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(NotificationChannel("mytify-downloads", "Pobieranie offline", NotificationManager.IMPORTANCE_LOW))
    }

    private fun notification(): Notification {
        val s = downloads.status()
        val items = s.getJSONArray("items")
        val running = (0 until items.length()).map { items.getJSONObject(it) }.firstOrNull { it.optString("state") == "running" }
        val pause = PendingIntent.getService(this, 11, Intent(this, DownloadService::class.java).setAction("pause"), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(this, 11, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val total = running?.optLong("total") ?: 0
        val done = running?.optLong("done") ?: 0
        return Notification.Builder(this, "mytify-downloads")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Mytify · Pobieranie (${items.length()})")
            .setContentText(running?.optString("title") ?: "Przygotowanie…")
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, if (total > 0) (done * 100 / total).toInt().coerceIn(0, 100) else 0, total <= 0)
            .addAction(Notification.Action.Builder(android.R.drawable.ic_media_pause, "Wstrzymaj", pause).build())
            .build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "pause") {
            downloads.pause(true)
            if (!started.get()) stopSelf()
            return START_NOT_STICKY
        }
        startForeground(211, notification())
        if (!started.compareAndSet(false, true)) return START_NOT_STICKY
        wake = (getSystemService(Context.POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Mytify:downloads").apply { acquire(2 * 60 * 60 * 1000L) }
        executor.execute {
            try {
                downloads.runQueue {
                    val now = SystemClock.elapsedRealtime()
                    if (now - last > 700) {
                        last = now
                        runCatching { getSystemService(NotificationManager::class.java).notify(211, notification()) }
                    }
                }
            } finally {
                wake?.takeIf { it.isHeld }?.release()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android's daily limit for background transfers: continue on the next start.
        downloads.stop = true
        stopSelf()
    }

    override fun onDestroy() {
        downloads.stop = true
        wake?.takeIf { it.isHeld }?.release()
        executor.shutdownNow()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
