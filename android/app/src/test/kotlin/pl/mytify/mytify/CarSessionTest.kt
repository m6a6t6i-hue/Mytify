package pl.mytify.mytify

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaBrowser
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.MediaSession
import com.google.common.util.concurrent.ListenableFuture
import org.junit.Assert.*
import org.junit.Before
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.android.controller.ServiceController
import java.util.concurrent.TimeUnit

@UnstableApi
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35])
class CarSessionTest {
    private lateinit var context: Context;private lateinit var lifecycle: ServiceController<PlaybackService>
    private lateinit var service: PlaybackService;private lateinit var catalog: Catalog
    private var browser: MediaBrowser?=null
    @Before fun setup() { context=RuntimeEnvironment.getApplication();context.deleteDatabase("catalog-android.sqlite3");context.getSharedPreferences("player",0).edit().clear().commit();catalog=Catalog(context) }
    @After fun close() { browser?.release();if(::lifecycle.isInitialized) lifecycle.destroy();catalog.close() }
    private fun start(): MediaLibrarySession {
        lifecycle=Robolectric.buildService(PlaybackService::class.java).create();service=lifecycle.get()
        return service.javaClass.getDeclaredField("session").let { it.isAccessible=true;it.get(service) as MediaLibrarySession }
    }
    private fun info(pkg: String=context.packageName,uid: Int=context.applicationInfo.uid,trusted: Boolean=false)=MediaSession.ControllerInfo.createTestOnlyControllerInfo(pkg,123,uid,1,1,trusted,Bundle.EMPTY,true)
    private fun <T> await(f: ListenableFuture<T>): T {
        val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(10)
        while(!f.isDone && System.nanoTime()<end) { shadowOf(Looper.getMainLooper()).idle();Thread.sleep(5) };return f.get(1,TimeUnit.SECONDS)
    }
    @Test fun untrustedUnknownControllerAndForgedAutoAreDenied() {
        val callback=CarSessionCallback(context,catalog,Handler(Looper.getMainLooper()))
        try { assertFalse(callback.allowed(info("other.app",424242)));assertFalse(callback.allowed(info("com.google.android.projection.gearhead",424242)));assertTrue(callback.allowed(info()));assertTrue(callback.allowed(info("system",424242,true))) } finally { callback.close() }
    }
    @Test fun realMediaBrowserCanBrowseServiceBeforeAnyActivityExists() {
        val session=start();val b=await(MediaBrowser.Builder(context,session.token).buildAsync());browser=b
        val root=await(b.getLibraryRoot(null));assertEquals(0,root.resultCode);assertEquals("root",root.value!!.mediaId)
        val children=await(b.getChildren("root",0,10,null));assertEquals(5,children.value!!.size)
        assertFalse(session.player.playWhenReady);assertEquals(0,session.player.mediaItemCount)
    }
    @Test fun browserSelectionAndPhoneControllerShareOneNativeQueue() {
        val provider=FilesProvider();provider.attachInfo(context,android.content.pm.ProviderInfo().apply { authority="test.documents" });org.robolectric.shadows.ShadowContentResolver.registerProviderInternal("test.documents",provider)
        val uris=(1..3).map { android.net.Uri.parse("content://test.documents/$it.mp3") };uris.forEachIndexed { i,u->provider.put(u,"sample$i") }
        val src=catalog.addSource(uris,false);catalog.scan(src) { _,_,_-> }
        val ids=(0..2).map { sha("sample$it".toByteArray()) };val p=PlaylistStore(catalog).save(null,"Drive",ids.reversed())
        val session=start();val b=await(MediaBrowser.Builder(context,session.token).buildAsync());browser=b
        val songs=await(b.getChildren("playlist:$p",0,100,null)).value!!
        b.setMediaItem(MediaItem.Builder().setMediaId(songs[1].mediaId).build())
        val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(10)
        while(session.player.mediaItemCount!=3 && System.nanoTime()<end) { shadowOf(Looper.getMainLooper()).idle();Thread.sleep(5) }
        assertEquals(ids.reversed(),(0 until session.player.mediaItemCount).map { session.player.getMediaItemAt(it).mediaId });assertEquals(ids[1],session.player.currentMediaItem!!.mediaId)
        val snapshot=service.snapshot(b);assertEquals(ids[1],snapshot.getString("currentId"));assertEquals(3,snapshot.getJSONArray("queueIds").length())
        b.seekToNextMediaItem();shadowOf(Looper.getMainLooper()).idle();assertEquals(ids[0],session.player.currentMediaItem!!.mediaId)
    }
    @Test fun manifestExposesLegacyBrowserAndCarMetadata() {
        val pm=context.packageManager
        for(action in listOf("android.media.browse.MediaBrowserService","androidx.media3.session.MediaLibraryService")) {
            val found=pm.queryIntentServices(android.content.Intent(action).setPackage(context.packageName),0)
            assertTrue(found.any { it.serviceInfo.name==PlaybackService::class.java.name })
        }
        val app=pm.getApplicationInfo(context.packageName,android.content.pm.PackageManager.GET_META_DATA)
        val xml=context.resources.getXml(app.metaData.getInt("com.google.android.gms.car.application"))
        var media=false
        while(xml.eventType!=org.xmlpull.v1.XmlPullParser.END_DOCUMENT) { if(xml.eventType==org.xmlpull.v1.XmlPullParser.START_TAG && xml.name=="uses" && xml.getAttributeValue(null,"name")=="media") media=true;xml.next() }
        xml.close();assertTrue(media)
    }
    @Test fun verifiedAutoUidGetsLibraryAndPlaybackCommands() {
        val pkg="com.google.android.projection.gearhead";val uid=333333
        val packageInfo=android.content.pm.PackageInfo().apply { packageName=pkg;applicationInfo=android.content.pm.ApplicationInfo().apply { packageName=pkg;this.uid=uid } }
        shadowOf(context.packageManager).installPackage(packageInfo)
        val callback=CarSessionCallback(context,catalog,Handler(Looper.getMainLooper()))
        try {
            val controller=info(pkg,uid);assertTrue(callback.allowed(controller))
            val session=start();val result=await(callback.onConnectAsync(session,controller))
            assertTrue(result.isAccepted)
            assertTrue(result.availableSessionCommands.contains(androidx.media3.session.SessionCommand.COMMAND_CODE_LIBRARY_GET_LIBRARY_ROOT))
            assertTrue(result.availablePlayerCommands.contains(androidx.media3.common.Player.COMMAND_CHANGE_MEDIA_ITEMS))
        } finally { callback.close() }
    }
}
