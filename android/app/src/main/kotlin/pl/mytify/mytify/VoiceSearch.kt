package pl.mytify.mytify

import android.content.Intent
import android.provider.MediaStore
import androidx.media3.common.MediaItem

internal fun voiceSearchItem(intent: Intent?): MediaItem? {
    if (intent?.action != MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH) return null
    val query = intent.getStringExtra(android.app.SearchManager.QUERY)?.trim() ?: ""
    if (query.length > 256) return null
    return MediaItem.Builder()
        .setRequestMetadata(MediaItem.RequestMetadata.Builder().setSearchQuery(query).build())
        .build()
}
