package pl.mytify.mytify

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.AtomicFile
import java.io.File
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class TransferManager(
    private val context: Context,
    private val peers: TransferPeers = EncryptedTransferPeers(context),
    private val client: TransferClient = TransferClient(),
) {
    val busy = AtomicBoolean(false)
    private val cancel = AtomicBoolean(false)
    private val catalog = Catalog(context)
    private val root = File(context.filesDir, "offline-music").apply { mkdirs() }
    private val checkpoint = AtomicFile(File(context.filesDir, "transfer-job.json"))
    private var job: JSONObject? =
        if (checkpoint.baseFile.exists())
            JSONObject(checkpoint.openRead().use { it.readBytes().toString(Charsets.UTF_8) })
        else null
    @Volatile var onProgress: (() -> Unit)? = null

    @Synchronized
    private fun persist() {
        val out = checkpoint.startWrite()
        try {
            out.write(job!!.toString().toByteArray())
            checkpoint.finishWrite(out)
        } catch (e: Exception) {
            checkpoint.failWrite(out)
            throw e
        }
    }

    @Synchronized
    private fun update(vararg values: Pair<String, Any?>, save: Boolean = false) {
        job?.let { j ->
            values.forEach { (k, v) -> j.put(k, v ?: JSONObject.NULL) }
            if (save) persist()
        }
        onProgress?.invoke()
    }

    @Synchronized
    fun status(): JSONObject {
        val j = job
        return obj(
            "state" to
                if (busy.get()) j?.optString("state", "queued")
                else if (j?.optString("state") == "complete") "complete"
                else if (j == null) "idle" else "paused",
            "doneBytes" to (j?.optLong("doneBytes") ?: 0),
            "totalBytes" to (j?.optLong("totalBytes") ?: 0),
            "done" to (j?.optInt("done") ?: 0),
            "total" to (j?.optJSONArray("tracks")?.length() ?: 0),
            "name" to j?.optString("current"),
            "error" to j?.optString("error"),
            "warnings" to (j?.optJSONArray("warnings") ?: JSONArray()),
            "peer" to j?.optString("peer"),
            "peers" to
                JSONArray(
                    peers.list().map { obj("id" to it.pin, "name" to it.name, "host" to it.host) }
                ),
        )
    }

    @Synchronized
    fun pair(link: String): JSONObject {
        check(!busy.get())
        val p = client.pair(link)
        peers.save(peers.list().filter { it.pin != p.pin } + p)
        return status()
    }

    private fun peer(id: String) =
        peers.list().firstOrNull { it.pin == id } ?: error("Komputer nie jest sparowany")

    fun manifest(id: String): JSONObject {
        val p = peer(id)
        val j = client.json(p, "/manifest")
        require(j.getInt("v") == 1 && j.getString("identity") == id)
        val tracks = j.getJSONArray("tracks")
        require(tracks.length() <= 10000)
        for (i in 0 until tracks.length()) {
            val t = tracks.getJSONObject(i)
            require(
                transferId(t.getString("id")) && t.getLong("size") in 1..20L * 1024 * 1024 * 1024
            )
        }
        return j
    }

    @Synchronized
    fun prepare(id: String, selected: List<String>, playlistIds: List<String>) {
        check(!busy.get()) { "Pobieranie już trwa" }
        check(job == null || job?.optString("state") == "complete") {
            "Wznów lub usuń poprzednie niedokończone pobranie"
        }
        val m = manifest(id)
        val ids = selected.toMutableSet()
        val lists = JSONArray()
        val allLists = m.optJSONArray("playlists") ?: JSONArray()
        for (i in 0 until allLists.length()) {
            val p = allLists.getJSONObject(i)
            if (p.getString("id") in playlistIds) {
                lists.put(p)
                ids.addAll(p.getJSONArray("ids").strings())
            }
        }
        require(ids.isNotEmpty() && ids.size <= 10000)
        val byId =
            (0 until m.getJSONArray("tracks").length())
                .map { m.getJSONArray("tracks").getJSONObject(it) }
                .associateBy { it.getString("id") }
        require(ids.all { it in byId }) { "Wybrany utwór nie jest już dostępny na PC" }
        val tracks = ids.map { byId.getValue(it) }
        var total = 0L
        var needed = 0L
        for (t in tracks) {
            val size = t.getLong("size")
            total = Math.addExact(total, size)
            val target = target(t)
            if (!target.isFile)
                needed =
                    Math.addExact(
                        needed,
                        (size - File(root, "${t.getString("id")}.part").length()).coerceAtLeast(0),
                    )
        }
        require(root.usableSpace > needed + 32L * 1024 * 1024) {
            "Za mało miejsca w telefonie. Potrzeba około ${needed/1024/1024+32} MB."
        }
        job =
            obj(
                "peer" to id,
                "tracks" to JSONArray(tracks),
                "playlists" to lists,
                "totalBytes" to total,
                "doneBytes" to 0L,
                "done" to 0,
                "state" to "queued",
                "error" to "",
                "warnings" to JSONArray(),
            )
        persist()
        cancel.set(false)
        busy.set(true)
    }

    @Synchronized
    fun reserveResume() {
        check(job != null && !busy.get())
        peer(job!!.getString("peer"))
        cancel.set(false)
        busy.set(true)
        update("state" to "queued", "error" to "", save = true)
    }

    fun pause() {
        cancel.set(true)
        client.abort()
    }

    fun release() {
        busy.set(false)
    }

    private fun target(t: JSONObject): File {
        val raw = t.optString("fileName").substringAfterLast('.').lowercase()
        val ext =
            if (
                raw in
                    setOf(
                        "mp3",
                        "flac",
                        "wav",
                        "m4a",
                        "mp4",
                        "aac",
                        "ogg",
                        "opus",
                        "aif",
                        "aiff",
                        "ape",
                        "wv",
                    )
            )
                raw
            else "audio"
        val id = t.getString("id")
        require(transferId(id))
        return File(root, "$id.$ext")
    }

    fun runJob() {
        try {
            val j = synchronized(this) { JSONObject(job!!.toString()) }
            val id = j.getString("peer")
            val p = peer(id)
            val tracks = j.getJSONArray("tracks")
            var bytes = 0L
            update("state" to "downloading", "error" to "", save = true)
            for (i in 0 until tracks.length()) {
                if (cancel.get()) throw CancellationException("Wstrzymano")
                val t = tracks.getJSONObject(i)
                val hash = t.getString("id")
                val size = t.getLong("size")
                val file = target(t)
                update("current" to t.getString("title"), "done" to i, "doneBytes" to bytes)
                if (
                    !file.isFile || file.length() != size || TransferClient.fileHash(file) != hash
                ) {
                    if (file.exists()) check(file.delete())
                    val part = File(root, "$hash.part")
                    client.download(p, hash, size, part, cancel) { n ->
                        update("doneBytes" to bytes + n)
                    }
                    check(part.renameTo(file)) { "Nie można zapisać pliku w telefonie" }
                }
                var cover: String? = null
                val art = t.optString("cover")
                if (transferId(art)) {
                    try {
                        cover = catalog.storeCover(client.cover(p, art)).getString("hash")
                    } catch (e: Exception) {
                        if (cancel.get()) throw CancellationException("Wstrzymano")
                        synchronized(this) {
                            val w = job!!.getJSONArray("warnings")
                            if (w.length() < 50)
                                w.put("Okładka ${t.optString("album")}: ${e.message}")
                        }
                    }
                }
                if (cancel.get()) throw CancellationException("Wstrzymano")
                catalog.registerOffline(id, p.name, t, file, cover)
                bytes += size
                update("done" to i + 1, "doneBytes" to bytes, save = true)
                Handler(Looper.getMainLooper()).post {
                    PlaybackService.instance?.libraryChanged()
                    LibraryChanges.changed()
                }
            }
            val lists = j.optJSONArray("playlists") ?: JSONArray()
            for (i in 0 until lists.length()) {
                val l = lists.getJSONObject(i)
                catalog.importOfflinePlaylist(
                    "pc:$id:${l.getString("id")}",
                    l.getString("name"),
                    l.getJSONArray("ids").strings(),
                )
            }
            update(
                "state" to "complete",
                "current" to "Gotowe — muzyka jest w telefonie",
                "error" to "",
                save = true,
            )
        } catch (e: Exception) {
            update(
                "state" to "paused",
                "error" to
                    if (cancel.get()) "Wstrzymano. Możesz wznowić pobieranie."
                    else (e.message ?: "Błąd pobierania"),
                save = true,
            )
        } finally {
            busy.set(false)
            onProgress?.invoke()
            Handler(Looper.getMainLooper()).post {
                PlaybackService.instance?.libraryChanged()
                LibraryChanges.changed()
            }
        }
    }

    @Synchronized
    fun forget(id: String) {
        check(!busy.get())
        peers.save(peers.list().filter { it.pin != id })
    }

    @Synchronized
    fun discard() {
        check(!busy.get()) { "Najpierw wstrzymaj pobieranie" }
        val tracks = job?.optJSONArray("tracks") ?: JSONArray()
        for (i in 0 until tracks.length()) {
            val id = tracks.getJSONObject(i).getString("id")
            require(transferId(id))
            val part = File(root, "$id.part")
            check(!part.exists() || part.delete()) { "Nie można usunąć pliku częściowego" }
        }
        checkpoint.delete()
        job = null
    }

    @Synchronized
    fun deleteCopies(id: String) {
        check(!busy.get())
        catalog.deleteOffline(id)
        if (job?.optString("peer") == id) discard()
        Handler(Looper.getMainLooper()).post {
            PlaybackService.instance?.libraryChanged()
            LibraryChanges.changed()
        }
    }

    companion object {
        @Volatile private var shared: TransferManager? = null

        fun get(context: Context) =
            shared
                ?: synchronized(this) {
                    shared ?: TransferManager(context.applicationContext).also { shared = it }
                }
    }
}

internal object LibraryChanges {
    val listeners = java.util.concurrent.CopyOnWriteArraySet<() -> Unit>()

    fun changed() {
        Handler(Looper.getMainLooper()).post { listeners.forEach { it() } }
    }
}
