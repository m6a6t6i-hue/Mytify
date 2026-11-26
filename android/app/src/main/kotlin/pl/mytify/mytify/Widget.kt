package pl.mytify.mytify

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import java.util.concurrent.Executors

/** Home screen widget: cover, title, artist and previous / play / next. Shows only what
 *  the player really has; with nothing loaded it says so and opens the app. */
@UnstableApi
class Widget : AppWidgetProvider() {
    data class State(
        val title: String,
        val artist: String,
        val artwork: Uri?,
        val playing: Boolean,
        val liked: Boolean,
    )

    companion object {
        const val TOGGLE = "pl.mytify.widget.TOGGLE"
        const val NEXT = "pl.mytify.widget.NEXT"
        const val PREVIOUS = "pl.mytify.widget.PREVIOUS"
        private val io = Executors.newSingleThreadExecutor()
        @Volatile private var lastArt: Uri? = null
        @Volatile private var lastBitmap: Bitmap? = null

        fun update(context: Context) {
            val app = context.applicationContext
            val manager = AppWidgetManager.getInstance(app) ?: return
            val ids = manager.getAppWidgetIds(ComponentName(app, Widget::class.java))
            if (ids.isEmpty()) return
            val state = PlaybackService.instance?.widgetState()
            io.execute {
                val art = state?.artwork
                val bitmap =
                    if (art == lastArt) lastBitmap
                    else (art?.let { load(app, it) }).also {
                        lastArt = art
                        lastBitmap = it
                    }
                runCatching { manager.updateAppWidget(ids, views(app, state, bitmap)) }
            }
        }

        /** Small copy of the cover, decoded here so the launcher needs no file access. */
        private fun load(c: Context, uri: Uri): Bitmap? =
            runCatching {
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    c.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
                    var sample = 1
                    while (bounds.outWidth / (sample * 2) >= 192 && bounds.outHeight / (sample * 2) >= 192) sample *= 2
                    c.contentResolver.openInputStream(uri)?.use {
                        BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
                    }
                }
                .getOrNull()

        private fun action(c: Context, name: String, code: Int): PendingIntent =
            PendingIntent.getBroadcast(
                c,
                code,
                Intent(c, Widget::class.java).setAction(name),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )

        private fun views(c: Context, state: State?, art: Bitmap?): RemoteViews =
            RemoteViews(c.packageName, R.layout.widget_player).apply {
                setTextViewText(R.id.widget_title, state?.title?.ifEmpty { null } ?: "Mytify")
                setTextViewText(
                    R.id.widget_artist,
                    if (state == null) "Nic nie gra. Dotknij, aby otworzyć." else state.artist,
                )
                if (art != null) setImageViewBitmap(R.id.widget_cover, art)
                else setImageViewResource(R.id.widget_cover, R.drawable.widget_cover_empty)
                setImageViewResource(
                    R.id.widget_toggle,
                    if (state?.playing == true) R.drawable.widget_pause else R.drawable.widget_play,
                )
                setContentDescription(R.id.widget_toggle, if (state?.playing == true) "Pauza" else "Odtwarzaj")
                setOnClickPendingIntent(R.id.widget_previous, action(c, PREVIOUS, 1))
                setOnClickPendingIntent(R.id.widget_toggle, action(c, TOGGLE, 2))
                setOnClickPendingIntent(R.id.widget_next, action(c, NEXT, 3))
                setOnClickPendingIntent(
                    R.id.widget_root,
                    PendingIntent.getActivity(
                        c,
                        0,
                        Intent(c, MainActivity::class.java),
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                    ),
                )
            }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) = update(context)

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val name = intent.action ?: return
        if (name != TOGGLE && name != NEXT && name != PREVIOUS) return
        // Same session as the app, Android Auto and the notification.
        val pending = goAsync()
        val future =
            MediaController.Builder(context, SessionToken(context, ComponentName(context, PlaybackService::class.java)))
                .buildAsync()
        future.addListener(
            {
                runCatching {
                    val p = future.get()
                    when (name) {
                        TOGGLE ->
                            if (p.isPlaying) p.pause()
                            else {
                                if (p.playbackState == Player.STATE_IDLE) p.prepare()
                                p.play()
                            }
                        NEXT -> p.seekToNextMediaItem()
                        PREVIOUS -> p.seekToPrevious()
                    }
                    p.release()
                }
                update(context)
                pending.finish()
            },
            ContextCompat.getMainExecutor(context),
        )
    }
}
