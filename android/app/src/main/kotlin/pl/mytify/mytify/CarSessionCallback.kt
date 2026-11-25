package pl.mytify.mytify

import android.content.Context
import android.os.Handler
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService.LibraryParams
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.MediaSession
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
                    MediaSession.ConnectionResult.DEFAULT_SESSION_AND_LIBRARY_COMMANDS
                )
                .setAvailablePlayerCommands(Player.Commands.Builder().addAllCommands().build())
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
        worker.submit(Callable { mediaItems.map { library.playable(it.mediaId) } })

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
            session.notifyChildrenChanged(it, if (it == CarLibrary.ROOT) 4 else Int.MAX_VALUE, null)
        }
    }

    fun close() {
        worker.shutdownNow()
    }
}
