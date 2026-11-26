package pl.mytify.mytify

import android.content.Context
import android.content.ContentValues
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Before
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@UnstableApi
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class CarLibraryTest {
    private lateinit var context: Context;private lateinit var catalog: Catalog;private lateinit var library: CarLibrary
    @Before fun setup() { context=RuntimeEnvironment.getApplication();context.deleteDatabase("catalog-android.sqlite3");catalog=Catalog(context);library=CarLibrary(context,catalog) }
    @After fun close() { catalog.close() }
    private fun add(n: Int,title: String="Song $n",album: String="Album",artist: String="Łódź",number: Int=n,available: Boolean=true): String {
        val id=sha("song$n".toByteArray());val raw=obj("title" to title,"artist" to artist,"album" to album,"albumArtist" to artist,"fileName" to "$n.flac","format" to "FLAC","trackNumber" to number,"discNumber" to 1,"size" to 100,"metadataSource" to "")
        catalog.writableDatabase.insertOrThrow("tracks",null,ContentValues().apply { put("id",id);put("raw",raw.toString());put("added",n) })
        catalog.writableDatabase.insertOrThrow("locations",null,ContentValues().apply { put("uri","content://test/$n");put("source","test");put("track",id);put("name","$n.flac");put("available",if(available) 1 else 0) });return id
    }
    @Test fun radioFolderListsFavouritesAndPlaysRememberedStationsWithoutTheApp() {
        assertEquals("stations:favorites",library.children("radio",0,100).first().mediaId)
        val s=Radio.Station("radio:abc","Jazz Radio","https://s.example/jazz",tags=listOf("jazz"),codec="AAC",bitrate=64)
        Radio.setFavorites(context,listOf(s,Radio.Station("bad","x","ftp://x")))
        val rows=library.children("stations:favorites",0,100)
        assertEquals(listOf("radio:abc"),rows.map { it.mediaId })
        assertTrue(rows.single().mediaMetadata.isPlayable==true)
        val item=library.playable("radio:abc")
        assertEquals("https://s.example/jazz",item.localConfiguration!!.uri.toString())
        assertEquals("Jazz Radio",item.mediaMetadata.station.toString())
        assertEquals("Jazz Radio",library.get("radio:abc").mediaMetadata.title.toString())
        assertThrows(IllegalStateException::class.java) { library.playable("radio:unknown") }
    }
    @Test fun stationQueueStartsWithFavouritesThenTheList() {
        val a=Radio.Station("radio:a","A","https://a/live");val b=Radio.Station("radio:b","B","https://b/live");val c=Radio.Station("radio:c","C","https://c/live")
        Radio.setFavorites(context,listOf(b))
        assertTrue(Radio.recent(context).none { it.id=="radio:b" })
        val (list,at)=Radio.queue(context,a,listOf(c,a,b))
        assertEquals(listOf("radio:b","radio:c","radio:a"),list.map { it.id });assertEquals(2,at)
        Radio.see(context,list)
        assertEquals("C",Radio.known(context,"radio:c")!!.name)
        assertEquals("https://c/live",library.playable("radio:c").localConfiguration!!.uri.toString())
        assertTrue(Radio.playlistPath("http://x/list.pls?a=1"));assertTrue(!Radio.playlistPath("http://x/live.mp3"))
    }
    @Test fun playlistFilesLeadToTheStream() {
        assertEquals("http://a.example:8000/live",Radio.parsePlaylist("[playlist]\nFile1=http://a.example:8000/live\nTitle1=A\n","http://x/"))
        assertEquals("https://c.example/s.mp3",Radio.parsePlaylist("#EXTM3U\n#EXTINF:-1,R\nhttps://c.example/s.mp3\n","http://x/"))
        assertEquals("http://x.example/stream/aac",Radio.parsePlaylist("stream/aac\n","http://x.example/list.m3u"))
        assertEquals("hls",Radio.parsePlaylist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\na.m3u8","http://x/"))
        assertEquals("http://d.example/live",Radio.parsePlaylist("<asx><entry><ref href=\"http://d.example/live\"/></entry></asx>","http://x/"))
        assertNull(Radio.parsePlaylist("<html></html>","http://x/"))
        val row=Radio.Station.directory(org.json.JSONObject("""{"stationuuid":"9617a958","name":" A ","url":"http://x/a.pls","url_resolved":"https://s/a","favicon":"javascript:x","tags":"Rock, ,Pop","hls":0}"""))!!
        assertEquals(listOf("radio:9617a958","A","https://s/a",""),listOf(row.id,row.name,row.url,row.logo));assertEquals(listOf("rock","pop"),row.tags)
    }
    @Test fun coldRootHasFiveCategoriesWithoutActivityOrMusic() { assertEquals(listOf("albums","playlists","liked","all","radio"),library.children("root",0,Int.MAX_VALUE).map { it.mediaId });assertTrue(library.children("all",0,100).isEmpty()) }
    @Test fun albumSelectionExpandsInDiscTrackOrderAndKeepsStart() {
        val three=add(3,number=3);val one=add(1,number=1);val two=add(2,number=2)
        val album=library.children("albums",0,100).single();val songs=library.children(album.mediaId,0,100)
        assertEquals(listOf(one,two,three),songs.map { CarLibrary.canonical(it.mediaId) })
        val result=library.resolve(listOf(songs[1]),0,C.TIME_UNSET);assertEquals(listOf(one,two,three),result.mediaItems.map { it.mediaId });assertEquals(1,result.startIndex)
    }
    @Test fun sameNamedAlbumsByDifferentArtistsAreSeparate() { add(1,artist="A");add(2,artist="B");assertEquals(2,library.children("albums",0,100).size) }
    @Test fun unavailableSongsAreAbsentFromBrowseAndQueue() { add(1);add(2,available=false);assertEquals(1,library.children("all",0,100).size);assertThrows(IllegalArgumentException::class.java) { library.playable(sha("song2".toByteArray())) } }
    @Test fun likedUpdatesAreVisibleWithoutRestart() { val id=add(1);assertTrue(library.children("liked",0,100).isEmpty());catalog.like(id,true);assertEquals(id,CarLibrary.canonical(library.children("liked",0,100).single().mediaId)) }
    @Test fun polishSearchAndSearchPlaybackReturnLocalResults() {
        val id=add(1,title="Światło",artist="Łódź");add(2,title="Else",artist="Other")
        assertEquals(id,CarLibrary.canonical(library.search("swiatlo lodz",0,20).single().mediaId))
        val request=MediaItem.Builder().setRequestMetadata(MediaItem.RequestMetadata.Builder().setSearchQuery("swiatlo").build()).build()
        assertEquals(id,library.resolve(listOf(request),0,0).mediaItems.single().mediaId)
    }
    @Test fun paginationHandlesLargeIntegersAndEmptyPages() { assertEquals(listOf(2,3),CarLibrary.page((0..5).toList(),1,2));assertTrue(CarLibrary.page(listOf(1),Int.MAX_VALUE,Int.MAX_VALUE).isEmpty());assertThrows(IllegalArgumentException::class.java) { CarLibrary.page(listOf(1),-1,2) } }
    @Test fun largeAlbumsAndTracksUseBoundedBrowsableRanges() {
        for(n in 1..105) add(n,album="Album $n")
        val albumBuckets=library.children("albums",0,Int.MAX_VALUE);assertEquals(2,albumBuckets.size)
        assertEquals(100,library.children(albumBuckets.first().mediaId,0,Int.MAX_VALUE).size)
        assertEquals(5,library.children(albumBuckets.last().mediaId,0,Int.MAX_VALUE).size)
        val buckets=library.children("all",0,Int.MAX_VALUE);assertEquals(2,buckets.size)
        assertEquals(10,library.children(buckets.first().mediaId,0,10).size)
        assertEquals(10,library.children(buckets.first().mediaId,1,10).size)
    }
    @Test fun arbitraryIncomingUrisCannotBecomePlaybackSources() {
        val id=add(1);val injected=MediaItem.Builder().setMediaId(id).setUri("https://evil.example/audio").build()
        val resolved=library.resolve(listOf(injected),0,0).mediaItems.single();assertEquals("content://test/1",resolved.localConfiguration!!.uri.toString())
        assertThrows(IllegalArgumentException::class.java) { library.playable("https://evil.example/audio") }
    }
    @Test fun playlistsPersistOrderAndExpandAsOneQueue() {
        val one=add(1);val two=add(2);val store=PlaylistStore(catalog);val id=store.save(null,"Moje",listOf(two,one))
        val folder=library.children("playlists",0,100).first { it.mediaId=="playlist:$id" };val songs=library.children(folder.mediaId,0,100)
        assertEquals(listOf(two,one),songs.map { CarLibrary.canonical(it.mediaId) });assertEquals(listOf(two,one),library.resolve(listOf(songs.first()),0,0).mediaItems.map { it.mediaId })
        catalog.close();catalog=Catalog(context);assertEquals(listOf(two,one),PlaylistStore(catalog).ids(id));PlaylistStore(catalog).delete(id);assertEquals(2,catalog.load().length())
    }
    @Test fun invalidPlaylistUpdateIsAtomic() { val id=add(1);val store=PlaylistStore(catalog);val p=store.save(null,"Name",listOf(id));assertThrows(IllegalArgumentException::class.java) { store.save(p,"Changed",listOf("missing")) };assertEquals("Name",store.list().getJSONObject(0).getString("name"));assertEquals(listOf(id),store.ids(p)) }
    @Test fun migrationFrom05PreservesTracksLikesAndSourceUris() {
        val id=add(1);catalog.like(id,true);val db=catalog.writableDatabase;db.execSQL("DROP TABLE playlist_tracks");db.execSQL("DROP TABLE playlists");db.version=1;catalog.close();catalog=Catalog(context)
        assertTrue(catalog.track(id).getBoolean("liked"));assertEquals(Uri.parse("content://test/1"),catalog.uri(id));assertEquals(4,catalog.readableDatabase.version);assertEquals(0,PlaylistStore(catalog).list().length())
    }
    @Test fun artworkUsesOnlyNarrowContentProviderPath() {
        val id=add(1);val bitmap=android.graphics.Bitmap.createBitmap(20,20,android.graphics.Bitmap.Config.ARGB_8888)
        val bytes=java.io.ByteArrayOutputStream();bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,bytes);bitmap.recycle()
        val cover=catalog.storeCover(bytes.toByteArray());catalog.edit(JSONArray().put(obj("id" to id,"patch" to obj("cover" to cover.getString("hash")))))
        val uri=library.playable(id).mediaMetadata.artworkUri!!
        assertEquals("content",uri.scheme);assertEquals(context.packageName+".covers",uri.authority);assertTrue(uri.path!!.startsWith("/covers/"))
        assertNotEquals(catalog.uri(id),uri)
    }
    @Test fun albumCaseAndWhitespaceVariantsShareOneAlbumAndQueue() {
        for(n in 1..8) add(n,album=if(n%2==0) "The duck knows where the river will flow" else "  the duck  knows where the river will flow  ",artist=if(n%2==0) "Everything will echo" else "everything will ECHO")
        val albums=library.children("albums",0,100);assertEquals(1,albums.size)
        val songs=library.children(albums.single().mediaId,0,100);assertEquals(8,songs.size)
        assertEquals(8,library.resolve(listOf(songs[3]),0,0).mediaItems.size)
    }
}
