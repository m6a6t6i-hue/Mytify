package pl.mytify.mytify

import android.content.Intent
import android.provider.MediaStore
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class VoiceSearchTest {
    @Test
    fun voiceIntentUsesSessionSearchWithoutAcceptingPathsOrOtherActions() {
        assertNull(
            voiceSearchItem(
                Intent(Intent.ACTION_VIEW).setData(android.net.Uri.parse("file:///private.mp3"))
            )
        )
        val request =
            Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH)
                .putExtra(android.app.SearchManager.QUERY, "  Światło Łódź  ")
        val item = voiceSearchItem(request)!!
        assertEquals("Światło Łódź", item.requestMetadata.searchQuery)
        assertNull(item.localConfiguration)
        assertEquals(
            "",
            voiceSearchItem(Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH))!!
                .requestMetadata
                .searchQuery,
        )
        assertNull(
            voiceSearchItem(request.putExtra(android.app.SearchManager.QUERY, "a".repeat(257)))
        )
    }

    @Test
    fun voiceSearchIntentResolvesToMytifyActivity() {
        val context = RuntimeEnvironment.getApplication()
        val matches =
            context.packageManager.queryIntentActivities(
                Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH)
                    .setPackage(context.packageName),
                android.content.pm.PackageManager.MATCH_DEFAULT_ONLY,
            )
        assertTrue(matches.any { it.activityInfo.name == "pl.mytify.mytify.MainActivity" })
    }
}
