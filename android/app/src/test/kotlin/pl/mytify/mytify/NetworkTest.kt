package pl.mytify.mytify
import android.content.pm.ProviderInfo
import android.net.Uri
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver
import java.net.HttpURLConnection
import java.net.URL
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35],manifest=Config.NONE)
class NetworkTest {
 @Test fun oneAirplayReceiverHasOneIdForRaopAndAirplayRecords() {
  val raop = NetworkDevices.airplayDeviceId("00A0DEDA4A79@RX-V481 DA4A79", "")
  val air = NetworkDevices.airplayDeviceId("RX-V481 DA4A79", "00:a0:de:da:4a:79")
  assertEquals("00:A0:DE:DA:4A:79", raop)
  assertEquals(raop, air)
  assertNull(NetworkDevices.airplayDeviceId("Kuchnia", ""))
 }
 @Test fun actualRangeServerReadsOnlyAuthorizedCatalogFileAndSupportsHead() {
  val context=RuntimeEnvironment.getApplication();context.deleteDatabase("catalog-android.sqlite3")
  val provider=FilesProvider();provider.attachInfo(context,ProviderInfo().apply { authority="test.network" });ShadowContentResolver.registerProviderInternal("test.network",provider)
  val uri=Uri.parse("content://test.network/track.mp3");provider.put(uri,"0123456789abcdef")
  Catalog(context).use { catalog->
   val source=catalog.addSource(listOf(uri),false);catalog.scan(source,explicit=true) { _,_,_-> };val id=catalog.load().getJSONObject(0).getString("id")
   NetworkFileServer(context,catalog,NetworkTarget("test","Test receiver","127.0.0.1",7000,"dlna")).use { server->
    val url=server.uri(id);val c=URL(url).openConnection() as HttpURLConnection;c.connectTimeout=2000;c.readTimeout=2000;c.setRequestProperty("Range","bytes=3-6");assertEquals(206,c.responseCode);assertEquals("bytes 3-6/16",c.getHeaderField("Content-Range"));assertEquals("3456",c.inputStream.bufferedReader().readText());c.disconnect()
    val head=URL(url).openConnection() as HttpURLConnection;head.requestMethod="HEAD";head.readTimeout=2000;assertEquals(200,head.responseCode);assertEquals(16,head.contentLength);assertEquals(0,head.inputStream.readBytes().size);head.disconnect()
    val bad=URL(url.replace(id,"../not-a-track")).openConnection() as HttpURLConnection;bad.readTimeout=2000;assertEquals(403,bad.responseCode);bad.disconnect()
   }
  }
 }
 @Test fun addressesAndXmlCannotReachExternalHostsOrEntities() {
  for(host in listOf("8.8.8.8","127.0.0.1","localhost","10.1.2.999","192.168.1.2.3"))assertFalse(NetworkDevices.privateHost(host))
  assertTrue(NetworkDevices.privateHost("192.168.1.2"));assertThrows(IllegalArgumentException::class.java){NetworkDevices.localUrl("http://8.8.8.8/")};assertThrows(Exception::class.java){NetworkDevices.document("<!DOCTYPE x [<!ENTITY ext SYSTEM 'file:///not-readable'>]><x>&ext;</x>")}
 }
 @Test fun rangesAndClockAreBounded(){assertEquals(7L to 9L,NetworkFileServer.parseRange("bytes=-3",10));assertNull(NetworkFileServer.parseRange("bytes=10-",10));assertNull(NetworkFileServer.parseRange("bytes=0-1,5-6",10));assertEquals(3723000L,DlnaPlayer.parseClock("1:02:03"))}
}
