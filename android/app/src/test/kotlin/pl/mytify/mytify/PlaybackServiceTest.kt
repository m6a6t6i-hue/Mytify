package pl.mytify.mytify

import android.content.Context
import org.robolectric.RuntimeEnvironment
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import org.junit.Assert.*
import org.junit.Before
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.android.controller.ServiceController

@UnstableApi
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35])
class PlaybackServiceTest {
    private lateinit var context: Context
    private lateinit var lifecycle: ServiceController<PlaybackService>
    private lateinit var service: PlaybackService
    @Before fun setup() { context=RuntimeEnvironment.getApplication();context.getSharedPreferences("player",0).edit().clear().commit();context.deleteDatabase("catalog-android.sqlite3") }
    @After fun cleanup() { if(::lifecycle.isInitialized) lifecycle.destroy() }
    private fun start() { lifecycle=Robolectric.buildService(PlaybackService::class.java).create();service=lifecycle.get() }
    private fun session()=service.javaClass.getDeclaredField("session").let { it.isAccessible=true;it.get(service) as MediaSession }
    @Test fun createsOnePlayerWithoutAutoplay() { start();assertSame(service,PlaybackService.instance);assertFalse(session().player.playWhenReady);assertEquals(0,session().player.mediaItemCount) }
    @Test fun savedVolumeRestoredWithoutPlayback() {
        context.getSharedPreferences("player",0).edit().putFloat("volume",0.35f).commit();start();assertEquals(0.35f,session().player.volume,0.001f);assertFalse(session().player.isPlaying);assertEquals(35.0,service.snapshot(session().player).getDouble("volume"),0.01)
    }
    @Test fun invalidSavedQueueDoesNotCrashOrPlay() {
        context.getSharedPreferences("player",0).edit().putString("queue","[\"missing\"]").putInt("index",999).commit();start();assertEquals(0,session().player.mediaItemCount);assertEquals(Player.STATE_IDLE,session().player.playbackState)
    }

    @Test fun restoreKeepsCurrentTrackAndModesWhenEarlierEntryIsMissing() {
        val provider=FilesProvider()
        provider.attachInfo(context,android.content.pm.ProviderInfo().apply { authority="test.documents" })
        org.robolectric.shadows.ShadowContentResolver.registerProviderInternal("test.documents",provider)
        val one=android.net.Uri.parse("content://test.documents/a.mp3")
        val two=android.net.Uri.parse("content://test.documents/b.mp3")
        provider.put(one,"one");provider.put(two,"two")
        Catalog(context).use { c -> val source=c.addSource(listOf(one,two),false);c.scan(source) { _,_,_-> } }
        val secondId=sha("two".toByteArray())
        context.getSharedPreferences("player",0).edit()
            .putString("queue",org.json.JSONArray(listOf("missing",sha("one".toByteArray()),secondId)).toString())
            .putInt("index",2).putLong("position",12345).putBoolean("repeat",true).putBoolean("shuffle",true).commit()
        start();val p=session().player
        assertEquals(2,p.mediaItemCount);assertEquals(secondId,p.currentMediaItem!!.mediaId)
        assertEquals(12345L,p.currentPosition);assertEquals(Player.REPEAT_MODE_ALL,p.repeatMode)
        assertTrue(p.shuffleModeEnabled);assertFalse(p.playWhenReady)
    }
}
