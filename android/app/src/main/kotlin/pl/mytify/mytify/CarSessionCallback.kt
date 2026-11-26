package pl.mytify.mytify

import android.content.Context
import android.os.Handler
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService.LibraryParams
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionError
import androidx.media3.session.SessionResult
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.MoreExecutors
import java.util.concurrent.Callable
import java.util.concurrent.Executors

@UnstableApi
class CarSessionCallback(
    private val context: Context,
    private val catalog: Catalog,
    private val handler: Handler,
) : MediaLibrarySession.Callback {
    private val worker = MoreExecutors.listeningDecorator(Executors.newSingleThreadExecutor())
    val library = CarLibrary(context, catalog)
    private val observed = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    companion object {
        /** Notification, lock screen and car buttons next to play, previous and next. */
        val LIKE = SessionCommand("pl.mytify.LIKE", android.os.Bundle.EMPTY)
        val SHUFFLE = SessionCommand("pl.mytify.SHUFFLE", android.os.Bundle.EMPTY)
    }

    /** Like and shuffle buttons showing the real state of the current track and queue. */
    fun buttons(player: Player): ImmutableList<CommandButton> {
        val id = player.currentMediaItem?.mediaId?.takeUnless { it.startsWith("radio:") }
        val liked = id != null && runCatching { catalog.liked(id) }.getOrDefault(false)
        val shuffle = player.shuffleModeEnabled
        return ImmutableList.of(
            CommandButton.Builder(if (liked) CommandButton.ICON_HEART_FILLED else CommandButton.ICON_HEART_UNFILLED)
                .setDisplayName(if (liked) Lang.t("Usuń z polubionych") else Lang.t("Polub"))
                .setSessionCommand(LIKE)
                .setEnabled(id != null)
                .build(),
            CommandButton.Builder(if (shuffle) CommandButton.ICON_SHUFFLE_ON else CommandButton.ICON_SHUFFLE_OFF)
                .setDisplayName(if (shuffle) Lang.t("Wyłącz losową kolejność") else Lang.t("Losowa kolejność"))
                .setSessionCommand(SHUFFLE)
                .build(),
        )
    }

    fun refreshButtons(session: MediaSession) {
        runCatching { session.setMediaButtonPreferences(buttons(session.player)) }
    }

    override fun onCustomCommand(
        session: MediaSession,
        controller: MediaSession.ControllerInfo,
        customCommand: SessionCommand,
        args: android.os.Bundle,
    ): ListenableFuture<SessionResult> {
        val p = session.player
        when (customCommand.customAction) {
            LIKE.customAction -> {
                val id = p.currentMediaItem?.mediaId?.takeUnless { it.startsWith("radio:") }
                    ?: return Futures.immediateFuture(SessionResult(SessionError.ERROR_BAD_VALUE))
                catalog.like(id, !catalog.liked(id))
                // The app and Android Auto show the new state too.
                LibraryChanges.changed()
            }
            SHUFFLE.customAction -> p.shuffleModeEnabled = !p.shuffleModeEnabled
            else -> return super.onCustomCommand(session, controller, customCommand, args)
        }
        refreshButtons(session)
        return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
    }

    fun allowed(info: MediaSession.ControllerInfo): Boolean {
        if (info.uid == context.applicationInfo.uid || info.isTrusted) return true
        return info.packageName == "com.google.android.projection.gearhead" &&
            context.packageManager.getPackagesForUid(info.uid)?.contains(info.packageName) == true
    }

    override fun onConnectAsync(
        session: MediaSession,
        controller: MediaSession.ControllerInfo,
    ): ListenableFuture<MediaSession.ConnectionResult> {
        if (!allowed(controller))
            return Futures.immediateFuture(MediaSession.ConnectionResult.reject())
        if (
            controller.packageName != context.packageName &&
                context.packageManager
                    .getPackagesForUid(controller.uid)
                    ?.contains(controller.packageName) == true
        ) {
            context.grantUriPermission(
                controller.packageName,
                android.net.Uri.parse("content://" + context.packageName + ".covers/covers/"),
                android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    android.content.Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
        }
        return Futures.immediateFuture(
            MediaSession.ConnectionResult.AcceptedResultBuilder(session, controller)
                .setAvailableSessionCommands(
                    MediaSession.ConnectionResult.DEFAULT_SESSION_AND_LIBRARY_COMMANDS.buildUpon()
                        .add(LIKE)
                        .add(SHUFFLE)
                        .build()
                )
                .setAvailablePlayerCommands(Player.Commands.Builder().addAllCommands().build())
                .setMediaButtonPreferences(buttons(session.player))
                .build()
        )
    }

    private fun <T : Any> result(task: () -> LibraryResult<T>): ListenableFuture<LibraryResult<T>> {
        val future = com.google.common.util.concurrent.SettableFuture.create<LibraryResult<T>>()
        worker.execute {
            try {
                future.set(task())
            } catch (_: Exception) {
                future.set(
                    LibraryResult.ofError<T>(androidx.media3.session.SessionError.ERROR_BAD_VALUE)
                )
            }
        }
        return future
    }

    override fun onGetLibraryRoot(
        session: MediaLibrarySession,
        browser: MediaSession.ControllerInfo,
        params: LibraryParams?,
    ): ListenableFuture<LibraryResult<MediaItem>> =
        Futures.immediateFuture(
            LibraryResult.ofItem(
                library.root(),
                LibraryParams.Builder()
                    .setExtras(library.root().mediaMetadata.extras ?: android.os.Bundle.EMPTY)
                    .setOffline(true)
                    .build(),
            )
        )

    override fun onGetChildren(
        session: MediaLibrarySession,
        browser: MediaSession.ControllerInfo,
        parentId: String,
        page: Int,
        pageSize: Int,
        params: LibraryParams?,
    ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = result {
        if (observed.size < 2048) observed.add(parentId)
        LibraryResult.ofItemList(
            library.children(parentId, page, pageSize, browser.packageName),
            params,
        )
    }

    override fun onGetItem(
        session: MediaLibrarySession,
        browser: MediaSession.ControllerInfo,
        mediaId: String,
    ): ListenableFuture<LibraryResult<MediaItem>> = result {
        LibraryResult.ofItem(library.get(mediaId, browser.packageName), null)
    }

    override fun onSearch(
        session: MediaLibrarySession,
        browser: MediaSession.ControllerInfo,
        query: String,
        params: LibraryParams?,
    ): ListenableFuture<LibraryResult<Void>> = result {
        require(query.isNotBlank() && query.length <= 256)
        val count = library.searchCount(query)
        handler.post { session.notifySearchResultChanged(browser, query, count, params) }
        LibraryResult.ofVoid()
    }

    override fun onGetSearchResult(
        session: MediaLibrarySession,
        browser: MediaSession.ControllerInfo,
        query: String,
        page: Int,
        pageSize: Int,
        params: LibraryParams?,
    ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = result {
        LibraryResult.ofItemList(library.search(query, page, pageSize, browser.packageName), params)
    }

    override fun onSetMediaItems(
        session: MediaSession,
        controller: MediaSession.ControllerInfo,
        mediaItems: List<MediaItem>,
        startIndex: Int,
        startPositionMs: Long,
    ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> =
        worker.submit(Callable { library.resolve(mediaItems, startIndex, startPositionMs) })

    override fun onAddMediaItems(
        session: MediaSession,
        controller: MediaSession.ControllerInfo,
        mediaItems: List<MediaItem>,
    ): ListenableFuture<List<MediaItem>> =
        worker.submit(Callable { mediaItems.map { if (it.mediaId.startsWith("radio:")) library.playableStation(it.mediaId) else library.playable(it.mediaId) } })

    override fun onPlaybackResumption(
        session: MediaSession,
        controller: MediaSession.ControllerInfo,
        isForPlayback: Boolean,
    ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> =
        worker.submit(
            Callable {
                val prefs = context.getSharedPreferences("player", 0)
                val ids = org.json.JSONArray(prefs.getString("queue", "[]")).strings()
                val saved = ids.getOrNull(prefs.getInt("index", 0))
                val items = ids.mapNotNull { runCatching { library.playable(it) }.getOrNull() }
                require(items.isNotEmpty())
                val index = items.indexOfFirst { it.mediaId == saved }
                MediaSession.MediaItemsWithStartPosition(
                    items,
                    maxOf(0, index),
                    if (index >= 0) maxOf(0, prefs.getLong("position", 0)) else 0,
                )
            }
        )

    fun changed(session: MediaLibrarySession) {
        val parents = synchronized(observed) { observed.toList() }
        (parents + listOf(CarLibrary.ROOT) + CarLibrary.ROOT_IDS).distinct().forEach {
            session.notifyChildrenChanged(it, if (it == CarLibrary.ROOT) CarLibrary.ROOT_IDS.size else Int.MAX_VALUE, null)
        }
    }

    fun close() {
        worker.shutdownNow()
    }
}
