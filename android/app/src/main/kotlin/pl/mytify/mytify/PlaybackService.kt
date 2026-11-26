package pl.mytify.mytify

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.MediaSession
import org.json.JSONArray
import org.json.JSONObject

@UnstableApi
class PlaybackService : MediaLibraryService() {
    private var session: MediaLibrarySession? = null
    private lateinit var carCallback: CarSessionCallback
    private lateinit var catalog: Catalog
    private val handler = Handler(Looper.getMainLooper())
    private val saver =
        object : Runnable {
            override fun run() {
                save()
                handler.postDelayed(this, 10000)
            }
        }

    companion object {
        var instance: PlaybackService? = null
            private set
    }

    /** Level copy of the local speaker output; null for AirPlay and DLNA. */
    @Volatile var levels: LevelSink? = null
        private set

    /** Band levels of what this phone plays now, or null when there is nothing real to show. */
    fun levelBands(): DoubleArray? =
        if (networkTarget != null || airplay != null) null else levels?.bands()

    private var airplay: AirplaySession? = null
    private var networkTarget: NetworkTarget? = null
    private val networkSaver =
        object : Runnable {
            override fun run() {
                airplay?.let { a ->
                    a.persist()
                    if (a.state() == 3) {
                        errorMessage = "AirPlay: ${a.text()}"
                        errorSerial++
                        session?.player?.pause()
                    }
                }
                handler.postDelayed(this, 1000)
            }
        }
    var errorMessage: String? = null
        private set

    var errorSerial = 0
        private set

    var revision = 0
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this
        catalog = Catalog(this)
        val p = createPlayer(null)
        val intent =
            PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        carCallback = CarSessionCallback(this, catalog, handler)
        session =
            MediaLibrarySession.Builder(this, p, carCallback).setSessionActivity(intent).build()
        restore(p)
        handler.postDelayed(saver, 10000)
        handler.postDelayed(networkSaver, 1000)
        watchNetwork()
    }

    private val prober = java.util.concurrent.Executors.newSingleThreadExecutor()
    private var networkCallback: android.net.ConnectivityManager.NetworkCallback? = null

    /** NAS reachability follows Wi-Fi changes, so offline shares fail fast and come back by themselves. */
    private fun watchNetwork() {
        val probe = {
            prober.execute {
                runCatching { NetworkSources.probe(applicationContext) }
                // Waiting downloads start when a suitable network appears (may need the app open).
                runCatching { Downloads.kick(applicationContext) }
            }
        }
        val cm = getSystemService(android.net.ConnectivityManager::class.java) ?: return
        val callback =
            object : android.net.ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: android.net.Network) {
                    probe()
                }

                override fun onLost(network: android.net.Network) {
                    probe()
                }
            }
        runCatching { cm.registerDefaultNetworkCallback(callback) }.onSuccess { networkCallback = callback }
        probe()
    }

    private fun createPlayer(a: AirplaySession?): ExoPlayer {
        levels = null
        val factory =
            if (a == null)
                object : DefaultRenderersFactory(this) {
                        // Same sink as before, with a read-only copy of the sound for the level display.
                        override fun buildAudioSink(
                            context: Context,
                            enableFloatOutput: Boolean,
                            enableAudioOutputPlaybackParams: Boolean,
                        ): AudioSink? =
                            super.buildAudioSink(context, enableFloatOutput, enableAudioOutputPlaybackParams)
                                ?.let { LevelSink(it).also { sink -> levels = sink } }
                    }
                    .setEnableAudioFloatOutput(true)
            else
                object : DefaultRenderersFactory(this) {
                    override fun buildAudioSink(
                        context: Context,
                        enableFloatOutput: Boolean,
                        enableAudioOutputPlaybackParams: Boolean,
                    ): AudioSink =
                        DefaultAudioSink.Builder(context)
                            .setEnableFloatOutput(false)
                            .setAudioProcessors(arrayOf<AudioProcessor>(AirplayProcessor(a)))
                            .build()
                }
        return ExoPlayer.Builder(this, factory)
            // smb:// locations stream from the NAS, everything else as before.
            .setMediaSourceFactory(
                androidx.media3.exoplayer.source.DefaultMediaSourceFactory(RoutingDataSource.Factory(this))
            )
            .build()
            .apply {
            setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                true,
            )
            setHandleAudioBecomingNoisy(true)
            setWakeMode(C.WAKE_MODE_LOCAL)
            volume = getSharedPreferences("player", 0).getFloat("volume", 0.8f)
            addListener(
                object : Player.Listener {
                    override fun onPlayerError(error: PlaybackException) {
                        errorMessage =
                            "Nie można odtworzyć pliku (${error.errorCodeName}). Sprawdź dostęp i format."
                        errorSerial++
                        revision++
                    }

                    override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                        revision++
                        save()
                        refreshButtons()
                        Widget.update(this@PlaybackService)
                    }

                    override fun onVolumeChanged(volume: Float) {
                        a?.volume(volume)
                        save()
                    }

                    override fun onIsPlayingChanged(isPlaying: Boolean) {
                        revision++
                        save()
                        Widget.update(this@PlaybackService)
                    }

                    override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                        if (!playWhenReady) a?.flush()
                    }

                    override fun onPositionDiscontinuity(
                        oldPosition: Player.PositionInfo,
                        newPosition: Player.PositionInfo,
                        reason: Int,
                    ) {
                        if (reason == Player.DISCONTINUITY_REASON_SEEK) a?.flush()
                    }

                    override fun onRepeatModeChanged(repeatMode: Int) {
                        save()
                    }

                    override fun onShuffleModeEnabledChanged(shuffleModeEnabled: Boolean) {
                        save()
                        refreshButtons()
                    }
                }
            )
        }
    }

    fun selectDevice(id: String) {
        if (id == (networkTarget?.id ?: "auto")) return
        val nextTarget =
            if (id == "auto") null
            else
                NetworkDevices.targets[id]
                    ?: error("Odbiornik jest niedostępny. Odśwież urządzenia.")
        require(nextTarget?.auth != 1) {
            "Odbiornik wymaga hasła AirPlay. Wyłącz hasło lub wybierz DLNA; obsługa tego trybu nie jest dostępna w 0.8."
        }
        val s = session ?: error("Brak sesji")
        val old = s.player
        val list = (0 until old.mediaItemCount).map { old.getMediaItemAt(it) }
        val index = maxOf(0, old.currentMediaItemIndex)
        val pos = maxOf(0, old.currentPosition)
        val playing = old.playWhenReady
        val rep = old.repeatMode
        val previousAir = airplay
        val nextAir = if (nextTarget?.kind == "airplay") AirplaySession(this, nextTarget) else null
        val next =
            if (nextTarget?.kind == "dlna")
                DlnaPlayer(this, catalog, nextTarget) { message ->
                    errorMessage = message
                    errorSerial++
                }
            else createPlayer(nextAir)
        old.pause()
        s.setPlayer(next)
        airplay = nextAir
        networkTarget = nextTarget
        old.release()
        previousAir?.close()
        if (list.isNotEmpty()) {
            next.setMediaItems(list, index, pos)
            next.repeatMode = rep
            next.prepare()
            if (playing) next.play()
        }
        clearError()
        save()
    }

    fun setNetworkVolume(value: Float) {
        airplay?.volume(value)
    }

    fun submitPin(pin: String) {
        (airplay ?: error("Brak sesji AirPlay")).pin(pin)
    }

    fun wakeReceiver() {
        (session?.player as? DlnaPlayer ?: error("Wybierz Yamahę przez DLNA")).wake()
    }

    fun item(id: String): MediaItem = carCallback.library.playable(id)

    fun clearError() {
        errorMessage = null
        revision++
    }

    fun save() {
        val p = session?.player ?: return
        getSharedPreferences("player", 0)
            .edit()
            .putString(
                "queue",
                JSONArray((0 until p.mediaItemCount).map { p.getMediaItemAt(it).mediaId })
                    .toString(),
            )
            .putInt("index", maxOf(0, p.currentMediaItemIndex))
            .putLong("position", maxOf(0, p.currentPosition))
            .putFloat("volume", p.volume)
            .putBoolean("repeat", p.repeatMode == Player.REPEAT_MODE_ALL)
            .putBoolean("shuffle", p.shuffleModeEnabled)
            .apply()
    }

    private fun restore(p: Player) {
        val prefs = getSharedPreferences("player", 0)
        runCatching {
            val ids = JSONArray(prefs.getString("queue", "[]")).strings()
            val savedIndex = prefs.getInt("index", 0)
            val savedId = ids.getOrNull(savedIndex)
            val savedPosition = maxOf(0, prefs.getLong("position", 0))
            val savedRepeat = prefs.getBoolean("repeat", false)
            val savedShuffle = prefs.getBoolean("shuffle", false)
            val items = ids.mapNotNull { runCatching { item(it) }.getOrNull() }
            if (items.isNotEmpty()) {
                val current = items.indexOfFirst { it.mediaId == savedId }
                p.setMediaItems(
                    items,
                    if (current >= 0) current else 0,
                    if (current >= 0) savedPosition else 0,
                )
                p.repeatMode = if (savedRepeat) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
                p.shuffleModeEnabled = savedShuffle
            }
        }
    }

    // Nie filtrujemy tutaj. Legacy MediaBrowser (Android Auto) wiąże usługę z placeholderem
    // ControllerInfo (pakiet android.media.browse.MediaBrowserService, uid bez znaczenia),
    // więc allowed() zawsze odrzucało bind i AA kręciło kółkiem w nieskończoność.
    // Kontrola dostępu zostaje w CarSessionCallback.onConnectAsync z prawdziwym ControllerInfo.
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? =
        session

    fun libraryChanged() {
        handler.post {
            val s = session ?: return@post
            carCallback.changed(s)
            // A like from the app changes the heart in the notification.
            carCallback.refreshButtons(s)
            Widget.update(this)
        }
    }

    fun refreshButtons() {
        handler.post { session?.let { carCallback.refreshButtons(it) } }
    }

    /** What the home screen widget shows: real track, artist, cover and play state. */
    fun widgetState(): Widget.State? {
        val p = session?.player ?: return null
        val item = p.currentMediaItem ?: return null
        val m = item.mediaMetadata
        return Widget.State(
            title = m.title?.toString() ?: "",
            artist = m.artist?.toString() ?: "",
            artwork = m.artworkUri,
            playing = p.isPlaying,
            liked = runCatching { catalog.liked(item.mediaId) }.getOrDefault(false),
        )
    }


    override fun onTaskRemoved(rootIntent: Intent?) {
        save()
        val p = session?.player
        if (
            p?.playWhenReady != true ||
                p.playbackState == Player.STATE_IDLE ||
                p.playbackState == Player.STATE_ENDED
        )
            stopSelf()
    }

    override fun onDestroy() {
        networkCallback?.let { cb ->
            runCatching { getSystemService(android.net.ConnectivityManager::class.java)?.unregisterNetworkCallback(cb) }
        }
        prober.shutdown()
        handler.removeCallbacks(saver)
        handler.removeCallbacks(networkSaver)
        save()
        session?.run {
            player.release()
            release()
        }
        session = null
        airplay?.close()
        airplay = null
        carCallback.close()
        catalog.close()
        instance = null
        super.onDestroy()
    }

    fun snapshotCurrent(): JSONObject = snapshot(session?.player ?: error("Brak odtwarzacza"))

    fun snapshot(p: Player): JSONObject {
        val f = (session?.player as? ExoPlayer)?.audioFormat
        return obj(
            "available" to true,
            "playing" to p.isPlaying,
            "completed" to (p.playbackState == Player.STATE_ENDED),
            "buffering" to (p.playbackState == Player.STATE_BUFFERING),
            "repeat" to (p.repeatMode == Player.REPEAT_MODE_ALL),
            "shuffled" to p.shuffleModeEnabled,
            "queueIds" to
                JSONArray((0 until p.mediaItemCount).map { p.getMediaItemAt(it).mediaId }),
            "currentId" to p.currentMediaItem?.mediaId,
            "index" to maxOf(0, p.currentMediaItemIndex),
            "error" to errorMessage,
            "errorSerial" to errorSerial,
            "revision" to revision,
            "underrunFrames" to 0,
            "renderedFrames" to 0,
            "volume" to p.volume * 100.0,
            "positionMs" to maxOf(0, p.currentPosition),
            "durationMs" to maxOf(0, p.duration),
            "selectedDevice" to (networkTarget?.id ?: "auto"),
            "pairingRequired" to (airplay?.state() == 2),
            "volumeAvailable" to ((session?.player as? DlnaPlayer)?.volumeKnown ?: true),
            "source" to
                f?.let {
                    obj(
                        "sampleRate" to it.sampleRate,
                        "bitDepth" to 0,
                        "channels" to it.channelCount,
                        "resampled" to false,
                    )
                },
            "output" to
                obj(
                    "name" to (networkTarget?.name ?: "Wyjście systemowe Android"),
                    "backend" to
                        (if (networkTarget?.kind == "airplay") "AirPlay · 16 bit / 44,1 kHz"
                        else if (networkTarget?.kind == "dlna") "DLNA · oryginalny plik"
                        else "Media3 / AudioTrack"),
                    "sampleRate" to (if (airplay != null) 44100 else 0),
                    "sampleFormat" to
                        (if (airplay != null) "PCM16 / ALAC" else "System / format pliku"),
                    "channels" to (if (networkTarget != null) 2 else 0),
                    "testSink" to false,
                ),
        )
    }
}
