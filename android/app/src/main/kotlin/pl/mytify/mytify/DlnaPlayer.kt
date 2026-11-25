package pl.mytify.mytify

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.*
import androidx.media3.common.util.UnstableApi
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import java.util.concurrent.Executors

/** Receiver state is authoritative; no local silent player or simulated clock. */
@UnstableApi
class DlnaPlayer(
    context: Context,
    private val catalog: Catalog,
    val target: NetworkTarget,
    private val report: (String) -> Unit,
) : SimpleBasePlayer(Looper.getMainLooper()) {
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val server = NetworkFileServer(context, catalog, target)
    private var items = emptyList<MediaItemData>()
    private var index = 0
    private var position = 0L
    private var wants = false
    private var ready = false
    private var loaded = false
    private var repeat = Player.REPEAT_MODE_OFF
    private var loudness = 0f
    private var seenPlaying = false
    @Volatile private var closed = false
    private var failure: PlaybackException? = null
    var volumeKnown = false
        private set

    private val tick =
        object : Runnable {
            override fun run() {
                if (closed) return
                io.execute {
                    if (loaded)
                        runCatching {
                                val state =
                                    NetworkDevices.xml(
                                        NetworkDevices.soap(target, "GetTransportInfo"),
                                        "CurrentTransportState",
                                    )
                                val p =
                                    NetworkDevices.xml(
                                        NetworkDevices.soap(target, "GetPositionInfo"),
                                        "RelTime",
                                    )
                                Triple(
                                    state,
                                    parseClock(p),
                                    runCatching {
                                            NetworkDevices.xml(
                                                    NetworkDevices.soap(
                                                        target,
                                                        "GetVolume",
                                                        mapOf("Channel" to "Master"),
                                                        true,
                                                    ),
                                                    "CurrentVolume",
                                                )
                                                .toFloat() / 100
                                        }
                                        .getOrNull()
                                        ?.takeIf { it.isFinite() && it in 0f..1f },
                                )
                            }
                            .onSuccess { (state, pos, vol) ->
                                main.post {
                                    if (!closed) {
                                        volumeKnown = vol != null
                                        if (vol != null) loudness = vol.coerceIn(0f, 1f)
                                        val previous = position
                                        position = pos
                                        val duration =
                                            (items.getOrNull(index)?.durationUs ?: 0) / 1000
                                        val advance =
                                            state == "STOPPED" &&
                                                seenPlaying &&
                                                duration > 0 &&
                                                maxOf(pos, previous) >= maxOf(0, duration - 2000)
                                        wants = state == "PLAYING"
                                        seenPlaying = seenPlaying || wants
                                        if (advance) {
                                            seenPlaying = false
                                            if (
                                                index + 1 < items.size ||
                                                    repeat == Player.REPEAT_MODE_ALL
                                            ) {
                                                val next =
                                                    if (index + 1 < items.size) index + 1 else 0
                                                seekTo(next, 0)
                                                play()
                                            }
                                        }
                                        invalidateState()
                                    }
                                }
                            }
                            .onFailure { e ->
                                main.post {
                                    if (!closed) {
                                        wants = false
                                        volumeKnown = false
                                        failure =
                                            PlaybackException(
                                                "Utracono łączność: ${e.message}",
                                                e,
                                                PlaybackException
                                                    .ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
                                            )
                                        report(failure!!.message ?: "Błąd odbiornika")
                                        invalidateState()
                                    }
                                }
                            }
                    main.postDelayed(this, 1000)
                }
            }
        }

    init {
        io.execute {
            val v =
                runCatching {
                        NetworkDevices.xml(
                                NetworkDevices.soap(
                                    target,
                                    "GetVolume",
                                    mapOf("Channel" to "Master"),
                                    true,
                                ),
                                "CurrentVolume",
                            )
                            .toFloat() / 100
                    }
                    .getOrNull()
                    ?.takeIf { it.isFinite() && it in 0f..1f }
            main.post {
                volumeKnown = v != null
                loudness = (v ?: 0f).coerceIn(0f, 1f)
                invalidateState()
            }
        }
        main.postDelayed(tick, 1000)
    }

    override fun getState(): State {
        val commands =
            Player.Commands.Builder()
                .addAll(
                    Player.COMMAND_PLAY_PAUSE,
                    Player.COMMAND_PREPARE,
                    Player.COMMAND_STOP,
                    Player.COMMAND_SET_MEDIA_ITEM,
                    Player.COMMAND_CHANGE_MEDIA_ITEMS,
                    Player.COMMAND_GET_TIMELINE,
                    Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
                    Player.COMMAND_GET_METADATA,
                    Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                    Player.COMMAND_SEEK_TO_MEDIA_ITEM,
                    Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
                    Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                    Player.COMMAND_SEEK_TO_NEXT,
                    Player.COMMAND_SEEK_TO_PREVIOUS,
                    Player.COMMAND_GET_VOLUME,
                    Player.COMMAND_SET_VOLUME,
                    Player.COMMAND_SET_REPEAT_MODE,
                )
                .build()
        return State.Builder()
            .setAvailableCommands(commands)
            .setPlaylist(items)
            .setCurrentMediaItemIndex(
                if (items.isEmpty()) C.INDEX_UNSET else index.coerceIn(0, items.lastIndex)
            )
            .setContentPositionMs(position)
            .setPlayWhenReady(wants, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .setPlaybackState(
                if (failure != null || !ready || items.isEmpty()) Player.STATE_IDLE
                else Player.STATE_READY
            )
            .setVolume(loudness)
            .setRepeatMode(repeat)
            .setPlayerError(failure)
            .build()
    }

    private fun task(block: () -> Unit): ListenableFuture<*> {
        val f = SettableFuture.create<Void>()
        io.execute {
            try {
                block()
                main.post {
                    failure = null
                    invalidateState()
                    f.set(null)
                }
            } catch (e: Exception) {
                main.post {
                    failure =
                        PlaybackException(
                            e.message,
                            e,
                            PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
                        )
                    wants = false
                    report(e.message ?: "Błąd odbiornika")
                    invalidateState()
                    f.setException(e)
                }
            }
        }
        return f
    }

    private fun update(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block()
        else {
            val f = SettableFuture.create<Void>()
            main.post {
                block()
                f.set(null)
            }
            f.get()
        }
    }

    private fun current(play: Boolean, pos: Long) {
        val id = items.getOrNull(index)?.mediaItem?.mediaId ?: return
        val track = catalog.track(id)
        val uri = server.uri(id)
        val mime = NetworkDevices.mime(track.optString("format"))
        val meta =
            "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"$id\" parentID=\"0\" restricted=\"1\"><dc:title>${NetworkDevices.escape(track.optString("title"))}</dc:title><upnp:artist>${NetworkDevices.escape(track.optString("artist"))}</upnp:artist><upnp:album>${NetworkDevices.escape(track.optString("album"))}</upnp:album><upnp:class>object.item.audioItem.musicTrack</upnp:class><res protocolInfo=\"http-get:*:$mime:*\">${NetworkDevices.escape(uri)}</res></item></DIDL-Lite>"
        NetworkDevices.soap(
            target,
            "SetAVTransportURI",
            mapOf("CurrentURI" to uri, "CurrentURIMetaData" to meta),
        )
        if (play) NetworkDevices.soap(target, "Play", mapOf("Speed" to "1"))
        if (pos > 0)
            NetworkDevices.soap(target, "Seek", mapOf("Unit" to "REL_TIME", "Target" to clock(pos)))
        update {
            loaded = true
            ready = true
            position = pos
            seenPlaying = false
            wants = play
        }
    }

    override fun handleSetMediaItems(
        mediaItems: List<MediaItem>,
        startIndex: Int,
        startPositionMs: Long,
    ): ListenableFuture<*> = task {
        require(mediaItems.size <= 10000)
        val data =
            mediaItems.map { item ->
                val id = item.mediaId
                val t = catalog.track(id)
                catalog.uri(id)
                MediaItemData.Builder(id)
                    .setMediaItem(item)
                    .setIsSeekable(true)
                    .setDurationUs(t.optLong("durationMs").coerceAtLeast(0) * 1000)
                    .build()
            }
        update {
            items = data
            index = startIndex.coerceIn(0, maxOf(0, data.lastIndex))
            position = maxOf(0, startPositionMs)
            loaded = false
            ready = false
            wants = false
        }
    }

    override fun handlePrepare(): ListenableFuture<*> = task {
        if (items.isNotEmpty()) current(wants, position)
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> = task {
        if (items.isEmpty()) return@task
        if (!loaded && playWhenReady) current(true, position)
        else if (loaded)
            NetworkDevices.soap(
                target,
                if (playWhenReady) "Play" else "Pause",
                if (playWhenReady) mapOf("Speed" to "1") else emptyMap(),
            )
        update { wants = playWhenReady }
    }

    override fun handleSeek(
        mediaItemIndex: Int,
        positionMs: Long,
        seekCommand: Int,
    ): ListenableFuture<*> = task {
        if (items.isEmpty()) return@task
        val i = mediaItemIndex.coerceIn(0, items.lastIndex)
        val pos = maxOf(0, positionMs)
        if (i != index || !loaded) {
            update { index = i }
            current(wants, pos)
        } else {
            NetworkDevices.soap(target, "Seek", mapOf("Unit" to "REL_TIME", "Target" to clock(pos)))
            update { position = pos }
        }
    }

    override fun handleSetVolume(volume: Float): ListenableFuture<*> = task {
        NetworkDevices.soap(
            target,
            "SetVolume",
            mapOf("Channel" to "Master", "DesiredVolume" to (volume * 100).toInt().toString()),
            true,
        )
        update { loudness = volume }
    }

    override fun handleSetRepeatMode(repeatMode: Int): ListenableFuture<*> = task {
        update { repeat = repeatMode }
    }

    override fun handleStop(): ListenableFuture<*> = task {
        if (loaded) NetworkDevices.soap(target, "Stop")
        update {
            wants = false
            ready = false
            loaded = false
        }
    }

    override fun handleRemoveMediaItems(fromIndex: Int, toIndex: Int): ListenableFuture<*> = task {
        val copy = items.toMutableList()
        copy.subList(fromIndex, toIndex).clear()
        if (loaded) NetworkDevices.soap(target, "Stop")
        update {
            items = copy
            index = 0
            position = 0
            loaded = false
            ready = false
            wants = false
        }
    }

    override fun handleRelease(): ListenableFuture<*> {
        closed = true
        main.removeCallbacks(tick)
        server.close()
        val f = SettableFuture.create<Void>()
        io.execute {
            runCatching { if (loaded) NetworkDevices.soap(target, "Stop") }
            io.shutdown()
            f.set(null)
        }
        return f
    }

    fun wake(): ListenableFuture<*> = task {
        NetworkDevices.http(
            NetworkDevices.localUrl(
                "http://${target.host}/YamahaExtendedControl/v1/main/setPower?power=on"
            )
        )
    }

    companion object {
        fun clock(ms: Long): String {
            val s = maxOf(0, ms) / 1000
            return "%d:%02d:%02d".format(java.util.Locale.ROOT, s / 3600, (s / 60) % 60, s % 60)
        }

        fun parseClock(value: String): Long {
            val p = value.split(':').mapNotNull { it.toDoubleOrNull() }
            return if (p.size == 3)
                ((p[0] * 3600 + p[1] * 60 + p[2]) * 1000).toLong().coerceAtLeast(0)
            else 0
        }
    }
}
