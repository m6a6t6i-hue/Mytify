package pl.mytify.mytify

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import org.robolectric.RuntimeEnvironment
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Before
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowContentResolver
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35],manifest=Config.NONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class CatalogTest {
    private lateinit var context: Context
    private lateinit var catalog: Catalog
    private lateinit var provider: FilesProvider
    private val one=Uri.parse("content://test.documents/one.mp3")
    private val two=Uri.parse("content://test.documents/two.mp3")
    @Before fun setup() {
        context=RuntimeEnvironment.getApplication();context.deleteDatabase("catalog-android.sqlite3")
        provider=FilesProvider();provider.attachInfo(context,android.content.pm.ProviderInfo().apply { authority="test.documents" })
        ShadowContentResolver.registerProviderInternal("test.documents",provider);catalog=Catalog(context)
    }
    @After fun cleanup() { catalog.close() }
    private fun add(uri: Uri=one,bytes: String="first audio data"): String {
        provider.put(uri,bytes);val source=catalog.addSource(listOf(uri),false);catalog.cancelled.set(false)
        val report=catalog.scan(source,explicit=true) { _,_,_-> };assertEquals(1,report.getInt("added"));return catalog.load().getJSONObject(0).getString("id")
    }
    @Test fun importUsesContentHashAndRetainsOriginal() {
        val id=add();assertEquals(sha("first audio data".toByteArray()),id);assertEquals(one,catalog.uri(id));assertEquals("first audio data",provider.files[one]!!.readText());assertEquals("one",catalog.track(id).getString("title"));assertTrue(catalog.track(id).getBoolean("available"))
    }
    @Test fun identicalContentInSecondLocationIsNotSecondTrack() {
        val id=add();provider.put(two,"first audio data");val src=catalog.addSource(listOf(two),false);assertEquals(1,catalog.scan(src) { _,_,_-> }.getInt("duplicates"));assertEquals(1,catalog.load().length());assertEquals(2,catalog.track(id).getInt("locationCount"))
    }
    @Test fun rescanAndReopenRetainManualMetadataAndLikes() {
        val id=add();catalog.like(id,true);catalog.edit(JSONArray().put(obj("id" to id,"patch" to obj("title" to "Łódź","album" to "Album"))))
        assertEquals(1,catalog.scan(null) { _,_,_-> }.getInt("unchanged"));catalog.close();catalog=Catalog(context)
        assertEquals("Łódź",catalog.track(id).getString("title"));assertTrue(catalog.track(id).getBoolean("liked"));catalog.reset(listOf(id));assertEquals("one",catalog.track(id).getString("title"));assertTrue(catalog.track(id).getBoolean("liked"))
    }
    @Test fun revokedSourceRetainsCatalogAndCanBeRecovered() {
        val id=add();catalog.like(id,true);provider.offline=true;val r=catalog.scan(null) { _,_,_-> };assertEquals(1,r.getInt("offlineSources"));assertFalse(catalog.track(id).getBoolean("available"));assertTrue(catalog.track(id).getBoolean("liked"));provider.offline=false;catalog.scan(null) { _,_,_-> };assertTrue(catalog.track(id).getBoolean("available"))
    }
    @Test fun forgottenTrackStaysIgnoredUntilExplicitImport() {
        val id=add();catalog.remove(id);assertEquals(0,catalog.load().length());assertEquals(1,catalog.scan(null) { _,_,_-> }.getInt("ignored"));assertTrue(provider.files[one]!!.exists());catalog.scan(null,explicit=true) { _,_,_-> };assertEquals(1,catalog.load().length())
    }
    @Test fun changedContentKeepsManualMetadataAndLikes() {
        val id=add();catalog.like(id,true);catalog.edit(JSONArray().put(obj("id" to id,"patch" to obj("title" to "My title"))));provider.put(one,"changed audio data");assertEquals(1,catalog.scan(null) { _,_,_-> }.getInt("updated"));val t=catalog.load().getJSONObject(0);assertNotEquals(id,t.getString("id"));assertEquals("My title",t.getString("title"));assertTrue(t.getBoolean("liked"));assertEquals(1,catalog.load().length())
    }
    @Test fun cancellationNeverMarksUnseenTracksMissing() { val id=add();catalog.cancelled.set(true);assertTrue(catalog.scan(null) { _,_,_-> }.getBoolean("cancelled"));assertTrue(catalog.track(id).getBoolean("available")) }
    @Test fun metadataBatchRollsBackOnInvalidField() {
        val id=add();val edits=JSONArray().put(obj("id" to id,"patch" to obj("title" to "changed"))).put(obj("id" to id,"patch" to obj("uri" to "malicious")));assertThrows(IllegalArgumentException::class.java) { catalog.edit(edits) };assertEquals("one",catalog.track(id).getString("title"))
    }
    @Test fun forgetSourceNeverDeletesMusic() { add();catalog.forget(catalog.sourceList().getJSONObject(0).getString("id"));assertEquals(0,catalog.load().length());assertTrue(provider.files[one]!!.exists()) }
    @Test fun playerCannotResolveArbitraryId() { assertThrows(IllegalStateException::class.java) { catalog.uri("../../file") } }
    @Test fun invalidCoverRejected() { assertThrows(IllegalArgumentException::class.java) { catalog.storeCover("not an image".toByteArray()) } }
    @Test fun missingOneFileDoesNotDisableTheOthers() {
        provider.put(one,"first");provider.put(two,"second");val source=catalog.addSource(listOf(one,two),false);catalog.scan(source) { _,_,_-> }
        provider.files.remove(one);val r=catalog.scan(source) { _,_,_-> };assertEquals(1,r.getInt("missing"));assertTrue(catalog.track(sha("second".toByteArray())).getBoolean("available"));assertFalse(catalog.track(sha("first".toByteArray())).getBoolean("available"))
    }
}
class FilesProvider: ContentProvider() {
    val files=HashMap<Uri,File>();var offline=false
    fun put(uri: Uri,text: String) { files.getOrPut(uri) { File(context!!.cacheDir,uri.lastPathSegment!!) }.writeText(text) }
    override fun onCreate()=true
    override fun query(uri: Uri,projection: Array<out String>?,selection: String?,args: Array<out String>?,sort: String?): Cursor {
        if(offline) throw SecurityException("Permission revoked");val f=files[uri]?:error("Missing file");return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE)).apply { addRow(arrayOf(f.name,f.length())) }
    }
    override fun openFile(uri: Uri,mode: String): ParcelFileDescriptor { if(offline) throw SecurityException("Permission revoked");return ParcelFileDescriptor.open(files[uri]?:error("Missing file"),ParcelFileDescriptor.MODE_READ_ONLY) }
    override fun getType(uri: Uri)="audio/mpeg"
    override fun insert(uri: Uri,values: ContentValues?): Uri?=null
    override fun delete(uri: Uri,selection: String?,args: Array<out String>?)=0
    override fun update(uri: Uri,values: ContentValues?,selection: String?,args: Array<out String>?)=0
}
