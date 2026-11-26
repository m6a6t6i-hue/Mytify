package pl.mytify.mytify

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

@UnstableApi
class MainActivity : FlutterActivity() {
    private lateinit var catalog: Catalog
    private lateinit var online: OnlineMetadata
    private val worker = Executors.newSingleThreadExecutor()
    private val networkWorker = Executors.newSingleThreadExecutor()
    private val audioWorker = Executors.newSingleThreadExecutor()
    /** Connection tests and folder browsing may wait for a slow NAS; never block the library. */
    private val sourceWorker = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private val uiExecutor = java.util.concurrent.Executor { main.post(it) }
    private var events: EventChannel.EventSink? = null
    private var picker: MethodChannel.Result? = null
    private var libraryNotify: (() -> Unit)? = null
    private var transferScanner: MethodChannel.Result? = null
    private var pickerKind = ""
    private var relinkId: String? = null
    private val importing = AtomicBoolean(false)
    private var controller: MediaController? = null
    private var controllerFuture:
        com.google.common.util.concurrent.ListenableFuture<MediaController>? =
        null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        catalog = Catalog(applicationContext)
        online = OnlineMetadata(applicationContext, catalog)
        sourceWorker.execute {
            runCatching { NetworkSources.probe(applicationContext) }
            // Downloads interrupted by closing the app continue now.
            runCatching { Downloads(applicationContext, catalog).refreshKept() }
            runCatching { Downloads.kick(applicationContext) }
        }
        EventChannel(engine.dartExecutor.binaryMessenger, "pl.mytify/import")
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                        events = sink
                    }

                    override fun onCancel(args: Any?) {
                        events = null
                    }
                }
            )
        val bridge = MethodChannel(engine.dartExecutor.binaryMessenger, "pl.mytify/library")
        bridge.setMethodCallHandler(::handle)
        libraryNotify = { bridge.invokeMethod("libraryChanged", null) }
        LibraryChanges.listeners.add(libraryNotify!!)
        controllerFuture =
            MediaController.Builder(
                    this,
                    SessionToken(this, ComponentName(this, PlaybackService::class.java)),
                )
                .buildAsync()
                .also { f ->
                    f.addListener(
                        {
                            runCatching {
                                controller = f.get()
                                consumeVoiceSearch(intent)
                            }
                        },
                        uiExecutor,
                    )
                }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumeVoiceSearch(intent)
    }

    private fun consumeVoiceSearch(value: Intent?) {
        val player = controller ?: return
        val item = voiceSearchItem(value) ?: return
        setIntent(Intent(value).setAction(null))
        player.setMediaItem(item)
        player.prepare()
        player.play()
    }

    private fun complete(r: MethodChannel.Result, v: Any?) {
        if (!isDestroyed) r.success(v?.toString() ?: "null")
    }

    private fun background(
        r: MethodChannel.Result,
        executor: java.util.concurrent.Executor = worker,
        task: () -> Any?,
    ) {
        executor.execute {
            try {
                val v = task()
                main.post { complete(r, v) }
            } catch (e: Exception) {
                main.post {
                    if (!isDestroyed)
                        r.error("mytify", e.message ?: "Operacja nie powiodła się", null)
                }
            }
        }
    }

    private fun changed() {
        PlaybackService.instance?.libraryChanged()
    }

    private fun progress(done: Int, total: Int, name: String) {
        main.post {
            events?.success(obj("done" to done, "total" to total, "name" to name).toString())
        }
    }

    private fun handle(call: MethodCall, r: MethodChannel.Result) {
        try {
            when (call.method) {
                "transfer" -> {
                    val args = JSONObject(call.arguments as String)
                    if (
                        args.optString("action") in listOf("startDownload", "resume") &&
                            android.os.Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                                android.content.pm.PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(
                            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                            410,
                        )
                    }
                    if (args.optString("action") == "scan") {
                        check(transferScanner == null)
                        transferScanner = r
                        val options =
                            com.journeyapps.barcodescanner
                                .ScanOptions()
                                .setDesiredBarcodeFormats(
                                    com.journeyapps.barcodescanner.ScanOptions.QR_CODE
                                )
                                .setPrompt("Zeskanuj kod Mytify z komputera lub telefonu")
                                .setBeepEnabled(false)
                                .setOrientationLocked(false)
                        startActivityForResult(options.createScanIntent(this), 409)
                    } else
                        background(r, networkWorker) {
                            val m = TransferManager.get(this)
                            when (args.optString("action")) {
                                // This phone shares its own music with another phone.
                                "share" -> PhoneShare.get(this).command(args.getJSONObject("request"))
                                "pair" -> m.pair(args.getString("link"))
                                "manifest" -> m.manifest(args.getString("id"))
                                "startDownload" -> {
                                    m.prepare(
                                        args.getString("id"),
                                        args.getJSONArray("ids").strings(),
                                        args.optJSONArray("playlists")?.strings() ?: emptyList(),
                                    )
                                    main.post {
                                        try {
                                            TransferService.launch(this)
                                        } catch (e: Exception) {
                                            m.pause()
                                            m.release()
                                        }
                                    }
                                    m.status()
                                }
                                "resume" -> {
                                    m.reserveResume()
                                    main.post {
                                        try {
                                            TransferService.launch(this)
                                        } catch (e: Exception) {
                                            m.pause()
                                            m.release()
                                        }
                                    }
                                    m.status()
                                }
                                "pause" -> {
                                    m.pause()
                                    m.status()
                                }
                                "forget" -> {
                                    m.forget(args.getString("id"))
                                    m.status()
                                }
                                "discard" -> {
                                    m.discard()
                                    m.status()
                                }
                                "deleteCopies" -> {
                                    m.deleteCopies(args.getString("id"))
                                    m.status()
                                }
                                else -> m.status()
                            }
                        }
                }
                "cancel" -> {
                    catalog.cancelled.set(true)
                    complete(r, JSONObject.NULL)
                }
                "import",
                "relink" -> {
                    check(!importing.get() && picker == null) { "Poczekaj na zakończenie importu" }
                    pickerKind =
                        if (call.method == "relink" || call.argument<Boolean>("folder") == true)
                            "folder"
                        else "files"
                    relinkId = if (call.method == "relink") call.argument<String>("id") else null
                    openPicker(
                        r,
                        if (pickerKind == "folder") Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                        else
                            Intent(Intent.ACTION_OPEN_DOCUMENT)
                                .setType("*/*")
                                .putExtra(
                                    Intent.EXTRA_MIME_TYPES,
                                    arrayOf("audio/*", "application/ogg"),
                                )
                                .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true),
                    )
                }
                "networkProtocols" -> r.success(JSONArray(NetworkSources.protocols).toString())
                "downloads" -> {
                    val args = JSONObject(call.arguments as String)
                    background(r, sourceWorker) {
                        val d = Downloads(applicationContext, catalog)
                        val ids = args.optJSONArray("ids")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
                        when (args.getString("action")) {
                            "status" -> d.status()
                            "estimate" -> d.estimate(ids)
                            "add" -> obj("queued" to d.add(ids, "user"))
                            "pause" -> obj("ok" to true).also { d.pause(args.optBoolean("paused")) }
                            "cancel" -> obj("ok" to true).also { d.cancel(ids) }
                            "remove" -> obj("ok" to true).also { d.remove(ids) }
                            "keep" -> obj("ok" to true).also { d.keep(args.getString("playlist"), args.optBoolean("keep")) }
                            "cellular" -> obj("ok" to true).also {
                                d.cellular = args.optBoolean("cellular")
                                Downloads.kick(applicationContext)
                            }
                            else -> error("Nieznana operacja.")
                        }
                    }
                }
                "played" -> {
                    val id = call.arguments as String
                    background(r, sourceWorker) {
                        catalog.played(id)
                        // Sent now if the server is reachable, otherwise kept for later.
                        catalog.serverLocations(id).map { it.first }.distinct().forEach { runCatching { catalog.flushPending(it) } }
                        obj("ok" to true)
                    }
                }
                "testSource", "browseSource", "saveSource" -> {
                    val args = JSONObject(call.arguments as String)
                    val id = args.optString("id").ifEmpty { null }
                    val config = args.getJSONObject("config")
                    background(r, sourceWorker) {
                        when (call.method) {
                            "testSource" -> NetworkSources.test(applicationContext, id, config)
                            "browseSource" ->
                                NetworkSources.browse(applicationContext, id, config, args.optString("path"))
                            else -> {
                                check(!importing.get() || id == null) { "Zaczekaj na zakończenie skanowania." }
                                obj("id" to catalog.saveNetwork(id, config)).also { changed() }
                            }
                        }
                    }
                }
                "sourceSettings" -> {
                    val id = call.arguments as String
                    background(r) {
                        (catalog.sourceSettings(id) ?: error("To źródło nie ma ustawień sieciowych."))
                            .put("hasPassword", !Secrets.load(applicationContext, id).isNullOrEmpty())
                    }
                }
                "openUrl" -> {
                    val url = call.argument<String>("url").orEmpty()
                    require(url.startsWith("https://") || url.startsWith("http://")) { "Nieprawidłowy adres" }
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    r.success(null)
                }
                "chooseCover" -> {
                    check(picker == null && !importing.get())
                    pickerKind = "cover"
                    openPicker(r, Intent(Intent.ACTION_OPEN_DOCUMENT).setType("image/*"))
                }
                "rescan" -> {
                    check(picker == null && importing.compareAndSet(false, true)) {
                        "Import już trwa"
                    }
                    catalog.cancelled.set(false)
                    background(r) {
                        try {
                            catalog.scan(call.argument<String>("id"), progress = ::progress).also {
                                changed()
                            }
                        } finally {
                            importing.set(false)
                        }
                    }
                }
                "audioDevices" -> background(r, networkWorker) { NetworkDevices.discover(this) }
                "audioState" -> withPlayer(r) { snapshot(it) }
                "audioLevels" -> {
                    val bands = PlaybackService.instance?.levelBands()
                    r.success(JSONObject().put("bands", bands?.let { JSONArray(it.toList()) } ?: JSONObject.NULL).toString())
                }
                "setLanguage" -> {
                    Lang.set(applicationContext, call.arguments as? String ?: "pl")
                    // Android Auto and the notification buttons follow at once.
                    PlaybackService.instance?.libraryChanged()
                    r.success(null)
                }
                "systemOutput" -> r.success(systemOutput())
                "openSystemOutputs" -> r.success(openSystemOutputs())
                "keepScreenOn" -> {
                    if (call.arguments == true) window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    r.success(null)
                }
                "audioCommand" -> {
                    val args = call.arguments as Map<*, *>
                    if (args["action"] == "load") {
                        val ids = (args["ids"] as List<*>).map { it as String }
                        require(ids.isNotEmpty() && ids.size <= 10000)
                        audioWorker.execute {
                            try {
                                val items = ids.map { mediaItem(it) }
                                main.post {
                                    withPlayer(r) { p ->
                                        p.setMediaItems(
                                            items,
                                            ((args["index"] as? Number)?.toInt() ?: 0).coerceIn(
                                                0,
                                                items.lastIndex,
                                            ),
                                            0,
                                        )
                                        PlaybackService.instance?.clearError()
                                        p.prepare()
                                        p.play()
                                        snapshot(p)
                                    }
                                }
                            } catch (e: Exception) {
                                main.post { if (!isDestroyed) r.error("audio", e.message, null) }
                            }
                        }
                    } else
                        withPlayer(r) { p ->
                            when (args["action"]) {
                                "play" -> {
                                    PlaybackService.instance?.clearError()
                                    if (
                                        p.playbackState == Player.STATE_IDLE ||
                                            p.playerError != null
                                    )
                                        p.prepare()
                                    if (p.playbackState == Player.STATE_ENDED) p.seekTo(0)
                                    p.play()
                                }
                                "pause" -> p.pause()
                                "stop" -> {
                                    p.stop()
                                    p.clearMediaItems()
                                }
                                "next" ->
                                    if (p.hasNextMediaItem()) {
                                        PlaybackService.instance?.clearError()
                                        p.seekToNextMediaItem()
                                        if (p.playbackState == Player.STATE_IDLE) p.prepare()
                                    } else {
                                        p.pause()
                                        p.seekTo(p.duration.coerceAtLeast(0))
                                    }
                                "previous" ->
                                    if (p.currentPosition > 3000) p.seekTo(0)
                                    else if (p.hasPreviousMediaItem()) {
                                        PlaybackService.instance?.clearError()
                                        p.seekToPreviousMediaItem()
                                        if (p.playbackState == Player.STATE_IDLE) p.prepare()
                                    } else p.seekTo(0)
                                "seek" ->
                                    p.seekTo(
                                        ((args["positionMs"] as? Number)?.toLong() ?: 0).coerceIn(
                                            0,
                                            p.duration.coerceAtLeast(0),
                                        )
                                    )
                                "volume" -> {
                                    val v =
                                        ((args["value"] as Number).toFloat() / 100f).coerceIn(
                                            0f,
                                            1f,
                                        )
                                    PlaybackService.instance?.setNetworkVolume(v)
                                    p.volume = v
                                }
                                "repeat" ->
                                    p.repeatMode =
                                        if (args["value"] == true) Player.REPEAT_MODE_ALL
                                        else Player.REPEAT_MODE_OFF
                                "shuffle" -> p.shuffleModeEnabled = args["value"] == true
                                "equalizer" ->
                                    Equalizer.set(
                                        args["enabled"] == true,
                                        (args["gains"] as? List<*>).orEmpty().map { (it as? Number)?.toFloat() ?: 0f },
                                        applicationContext,
                                    )
                                "jump" -> {
                                    val i =
                                        (0 until p.mediaItemCount).firstOrNull {
                                            p.getMediaItemAt(it).mediaId == args["id"]
                                        } ?: error("Utwór nie należy do kolejki")
                                    p.seekTo(i, 0)
                                    p.prepare()
                                    p.play()
                                }
                                "device" ->
                                    PlaybackService.instance?.selectDevice(args["id"] as String)
                                "pin" ->
                                    PlaybackService.instance?.submitPin(args["value"] as String)
                                "receiverPower" -> PlaybackService.instance?.wakeReceiver()
                                else -> error("Nieznane polecenie audio")
                            }
                            PlaybackService.instance?.save()
                            snapshot(p)
                        }
                }
                else ->
                    background(r) {
                        when (call.method) {
                            "load" -> catalog.load()
                            "sources" -> catalog.sourceList()
                            "uri" ->
                                JSONObject.quote(catalog.uri(call.arguments as String).toString())
                            "like" -> {
                                val liked = call.argument<String>("id")!!
                                catalog.like(liked, call.argument<Boolean>("value") == true)
                                // Music servers get the change now if reachable, otherwise later.
                                sourceWorker.execute {
                                    catalog.serverLocations(liked).map { it.first }.distinct().forEach {
                                        runCatching { catalog.flushPending(it) }
                                    }
                                }
                                changed()
                                JSONObject.NULL
                            }
                            "remove" -> {
                                catalog.remove(call.arguments as String)
                                changed()
                                JSONObject.NULL
                            }
                            "forget" -> {
                                catalog.forget(call.arguments as String)
                                changed()
                                JSONObject.NULL
                            }
                            "edit" -> {
                                catalog.edit(JSONArray(call.arguments as String))
                                changed()
                                JSONObject.NULL
                            }
                            "reset" -> {
                                catalog.reset((call.arguments as List<*>).map { it as String })
                                changed()
                                JSONObject.NULL
                            }
                            "playlists" -> PlaylistStore(catalog).list()
                            "savePlaylist" -> {
                                val id =
                                    PlaylistStore(catalog)
                                        .save(
                                            call.argument<String>("id"),
                                            call.argument<String>("name")!!,
                                            call.argument<List<String>>("ids")!!,
                                        )
                                // A playlist kept offline downloads what was added to it.
                                sourceWorker.execute { runCatching { Downloads(applicationContext, catalog).refreshKept() } }
                                changed()
                                JSONObject.quote(id)
                            }
                            "deletePlaylist" -> {
                                PlaylistStore(catalog).delete(call.arguments as String)
                                changed()
                                JSONObject.NULL
                            }
                            "findReleases" ->
                                online.search(
                                    call.argument<String>("album") ?: "",
                                    call.argument<String>("artist") ?: "",
                                )
                            "releaseDetails" -> online.details(call.arguments as String)
                            "downloadCover" -> online.cover(call.arguments as String)
                            else -> error("Nieznana operacja")
                        }
                    }
            }
        } catch (e: Exception) {
            r.error("mytify", e.message, null)
        }
    }

    private fun mediaItem(id: String): MediaItem {
        val t = catalog.track(id)
        return MediaItem.Builder()
            .setMediaId(id)
            .setUri(catalog.uri(id))
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(t.optString("title"))
                    .setArtist(t.optString("artist"))
                    .setAlbumTitle(t.optString("album"))
                    .setArtworkUri(catalog.artwork(id))
                    .build()
            )
            .build()
    }

    private fun withPlayer(r: MethodChannel.Result, task: (MediaController) -> JSONObject) {
        if (isDestroyed) return
        val p = controller
        if (p == null || !p.isConnected) {
            val f = controllerFuture
            if (f == null) {
                r.error("audio", "Brak usługi odtwarzania", null)
                return
            }
            f.addListener(
                {
                    if (!isDestroyed)
                        try {
                            val ready = f.get()
                            controller = ready
                            check(ready.isConnected)
                            complete(r, task(ready))
                        } catch (e: Exception) {
                            r.error("audio", "Nie można połączyć z odtwarzaczem", null)
                        }
                },
                uiExecutor,
            )
            return
        }
        try {
            complete(r, task(p))
        } catch (e: Exception) {
            r.error("audio", e.message, null)
        }
    }

    private fun snapshot(p: Player): JSONObject =
        PlaybackService.instance?.snapshotCurrent() ?: error("Usługa odtwarzania jest niedostępna")

    private fun openPicker(r: MethodChannel.Result, intent: Intent) {
        picker = r
        try {
            startActivityForResult(
                intent.addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                ),
                407,
            )
        } catch (e: Exception) {
            picker = null
            throw e
        }
    }

    @Deprecated("SAF activity result retained for FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 409) {
            val r = transferScanner
            transferScanner = null
            if (r != null)
                complete(
                    r,
                    if (resultCode == RESULT_OK)
                        org.json.JSONObject.quote(data?.getStringExtra("SCAN_RESULT"))
                    else JSONObject.NULL,
                )
            return
        }
        if (requestCode != 407) return
        val r = picker ?: return
        picker = null
        if (resultCode != RESULT_OK || data == null) {
            complete(r, if (pickerKind == "cover") JSONObject.NULL else obj("cancelled" to true))
            return
        }
        val uris = mutableListOf<Uri>()
        data.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        }
        if (uris.isEmpty()) data.data?.let { uris.add(it) }
        if (uris.isEmpty()) {
            r.error("picker", "Nie wybrano plików", null)
            return
        }
        val kind = pickerKind
        val relink = relinkId
        if (kind == "cover") {
            background(r) {
                (contentResolver.openInputStream(uris.first())
                        ?: error("Nie można otworzyć obrazu"))
                    .use { catalog.storeCover(readLimited(it, 8 * 1024 * 1024)) }
            }
            return
        }
        importing.set(true)
        catalog.cancelled.set(false)
        background(r) {
            try {
                uris.distinct().forEach { uri ->
                    try {
                        contentResolver.takePersistableUriPermission(
                            uri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION,
                        )
                    } catch (e: SecurityException) {
                        error(
                            "Dostawca nie pozwala zapamiętać dostępu. Wybierz pliki w pamięci telefonu lub folder Muzyka."
                        )
                    }
                }
                val id = catalog.addSource(uris.distinct(), kind == "folder", relink)
                catalog.scan(id, explicit = true, progress = ::progress).also { changed() }
            } finally {
                importing.set(false)
            }
        }
    }

    override fun onDestroy() {
        libraryNotify?.let { LibraryChanges.listeners.remove(it) }
        libraryNotify = null
        transferScanner?.error("cancelled", "Skanowanie przerwane", null)
        transferScanner = null
        catalog.cancelled.set(true)
        worker.shutdown()
        audioWorker.shutdown()
        networkWorker.shutdown()
        controllerFuture?.let { MediaController.releaseFuture(it) }
        events = null
        super.onDestroy()
    }

    /** Where Android sends media right now (when Mytify plays on "this phone"). */
    private fun systemOutput(): Map<String, Any> {
        val am = getSystemService(AUDIO_SERVICE) as android.media.AudioManager
        val routed =
            if (android.os.Build.VERSION.SDK_INT >= 33)
                runCatching {
                        am.getAudioDevicesForAttributes(
                            android.media.AudioAttributes.Builder()
                                .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                                .build()
                        )
                    }
                    .getOrDefault(emptyList())
            else emptyList()
        val pool = routed.ifEmpty { am.getDevices(android.media.AudioManager.GET_DEVICES_OUTPUTS).toList() }
        fun kind(d: android.media.AudioDeviceInfo) =
            when (d.type) {
                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                26, // TYPE_BLE_HEADSET
                27, // TYPE_BLE_SPEAKER
                30 -> "bluetooth" // TYPE_BLE_BROADCAST
                android.media.AudioDeviceInfo.TYPE_USB_HEADSET,
                android.media.AudioDeviceInfo.TYPE_USB_DEVICE -> "usb"
                android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET,
                android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired"
                android.media.AudioDeviceInfo.TYPE_HDMI -> "hdmi"
                android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
                else -> ""
            }
        val rank = listOf("bluetooth", "usb", "wired", "hdmi", "speaker")
        val d = pool.filter { kind(it).isNotEmpty() }.minByOrNull { rank.indexOf(kind(it)) }
            ?: return mapOf("kind" to "speaker", "name" to "")
        val k = kind(d)
        val name = if (k == "bluetooth" || k == "usb") d.productName?.toString() ?: "" else ""
        return mapOf("kind" to k, "name" to name)
    }

    /** The system picker for Bluetooth and other outputs, the same one other players open. */
    private fun openSystemOutputs(): Boolean {
        if (android.os.Build.VERSION.SDK_INT >= 34 &&
            runCatching { android.media.MediaRouter2.getInstance(this).showSystemOutputSwitcher() }
                .getOrDefault(false)
        ) return true
        if (android.os.Build.VERSION.SDK_INT >= 31) {
            val i = Intent("com.android.systemui.action.LAUNCH_MEDIA_OUTPUT_DIALOG")
                .setPackage("com.android.systemui")
                .putExtra("package_name", packageName)
            if (packageManager.queryBroadcastReceivers(i, 0).isNotEmpty()) {
                sendBroadcast(i)
                return true
            }
        }
        if (android.os.Build.VERSION.SDK_INT >= 30 &&
            runCatching {
                    startActivity(
                        Intent("com.android.settings.panel.action.MEDIA_OUTPUT")
                            .putExtra("com.android.settings.panel.extra.PACKAGE_NAME", packageName)
                    )
                }
                .isSuccess
        ) return true
        return runCatching { startActivity(Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS)) }.isSuccess
    }
}
