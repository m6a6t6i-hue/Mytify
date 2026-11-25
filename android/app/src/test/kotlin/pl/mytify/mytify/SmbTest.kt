package pl.mytify.mytify

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.DataSpec
import java.io.File
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], manifest = Config.NONE)
class SmbTest {
    private lateinit var context: Context
    private lateinit var catalog: Catalog

    @Before
    fun setup() {
        context = RuntimeEnvironment.getApplication()
        context.deleteDatabase("catalog-android.sqlite3")
        Secrets.memory = mutableMapOf()
        catalog = Catalog(context)
        NetworkSources.shared = catalog
    }

    @After
    fun cleanup() {
        NetworkSources.shared = null
        catalog.close()
        Secrets.memory = null
    }

    private fun config(vararg f: Pair<String, Any?>) = obj("protocol" to "smb", *f)

    private fun noop(done: Int, total: Int, name: String) {}

    @Test
    fun settingsAreCleanedLikeOnPc() {
        val s = SmbSettings.parse(config("host" to "\\\\Synology\\", "share" to "/music/", "folder" to "\\Albumy\\Polskie ąę/"))
        assertEquals("Synology", s.host)
        assertEquals("music", s.share)
        assertEquals("Albumy/Polskie ąę", s.folder)
        assertEquals("Polskie ąę", s.name)
        assertEquals("\\\\Synology\\music\\Albumy\\Polskie ąę", s.address)
        assertEquals("Albumy\\Polskie ąę\\a.flac", s.inside("a.flac"))
        for (bad in listOf(config("host" to "nas", "share" to "m", "folder" to "../x"), config("host" to "", "share" to "m"), config("host" to "nas", "share" to "a:b"))) {
            assertThrows(IllegalArgumentException::class.java) { SmbSettings.parse(bad) }
        }
        assertFalse(s.json().toString().contains("password"))
    }

    @Test
    fun locationUriKeepsPolishNamesAndSpaces() {
        val u = Smb.uri("abc", "Muzyka/Zażółć gęślą jaźń/01 a#b.flac")
        assertEquals("smb", u.scheme)
        assertEquals("abc", u.authority)
        assertEquals("Muzyka/Zażółć gęślą jaźń/01 a#b.flac", Uri.parse(u.toString()).pathSegments.joinToString("/"))
    }

    @Test
    fun upgradeFromV2KeepsLikesAndPlaylists() {
        catalog.close()
        context.deleteDatabase("catalog-android.sqlite3")
        val path = context.getDatabasePath("catalog-android.sqlite3").apply { parentFile?.mkdirs() }
        SQLiteDatabase.openOrCreateDatabase(path, null).use { db ->
            db.execSQL("CREATE TABLE tracks(id TEXT PRIMARY KEY,raw TEXT NOT NULL,patch TEXT NOT NULL DEFAULT '{}',liked INTEGER NOT NULL DEFAULT 0,added INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE sources(id TEXT PRIMARY KEY,uri TEXT NOT NULL,name TEXT NOT NULL,kind TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'partial',scanned INTEGER NOT NULL DEFAULT 0)")
            db.execSQL("CREATE TABLE locations(uri TEXT NOT NULL,source TEXT NOT NULL,track TEXT NOT NULL,name TEXT NOT NULL,available INTEGER NOT NULL DEFAULT 1,PRIMARY KEY(uri,source))")
            db.execSQL("CREATE INDEX location_track ON locations(track)")
            db.execSQL("CREATE TABLE ignored(uri TEXT PRIMARY KEY)")
            PlaylistStore.create(db)
            db.execSQL("INSERT INTO tracks VALUES('t1','{\"title\":\"Stary\"}','{}',1,1)")
            db.execSQL("INSERT INTO sources VALUES('s1','content://x','Muzyka','folder','online',1)")
            db.execSQL("INSERT INTO locations VALUES('content://x/1','s1','t1','a.mp3',1)")
            db.version = 2
        }
        catalog = Catalog(context)
        NetworkSources.shared = catalog
        val t = catalog.track("t1")
        assertTrue(t.getBoolean("liked"))
        assertEquals("Stary", t.getString("title"))
        assertTrue(t.getBoolean("available"))
        assertEquals(1, catalog.sourceList().length())
    }

    @Test
    fun unreachableShareKeepsCollectionAndFailsFast() {
        val id = catalog.saveSmb(null, config("host" to "mytify-missing-nas.invalid", "share" to "music", "user" to "mat", "password" to "x"))
        assertEquals("x", Secrets.load(context, id))
        val source = catalog.sourceList().getJSONObject(0)
        assertEquals("smb", source.getString("protocol"))
        assertEquals("\\\\mytify-missing-nas.invalid\\music", source.getString("address"))
        assertFalse(source.toString().contains("\"x\""))
        // A track found earlier on the NAS.
        catalog.writableDatabase.execSQL("INSERT INTO tracks(id,raw,patch,liked,added) VALUES('nas1','{\"title\":\"Z NAS\"}','{}',1,1)")
        catalog.writableDatabase.execSQL("INSERT INTO locations(uri,source,track,name,available) VALUES('smb://$id/a.flac','$id','nas1','a.flac',1)")
        val report = catalog.scan(id, progress = ::noop)
        assertEquals(1, report.getInt("offlineSources"))
        assertEquals(0, report.getInt("missing"))
        val t = catalog.track("nas1")
        assertTrue("liked survives", t.getBoolean("liked"))
        assertEquals(1, t.getInt("locationCount"))
        assertFalse("offline share is not playable", t.getBoolean("available"))
        val started = System.nanoTime()
        assertThrows(IllegalStateException::class.java) { catalog.uri("nas1") }
        assertTrue("no network wait", System.nanoTime() - started < 1_000_000_000L)
        catalog.forget(id)
        assertNull(Secrets.load(context, id))
    }

    /** Real Samba share, prepared by CI (see .github/workflows/android.yml). */
    @Test
    fun realShareScanPlaySeek() {
        val host = System.getenv("MYTIFY_SMB_HOST")
        assumeTrue("MYTIFY_SMB_HOST not set", host != null)
        val user = System.getenv("MYTIFY_SMB_USER")
        val password = System.getenv("MYTIFY_SMB_PASSWORD")
        val share = System.getenv("MYTIFY_SMB_SHARE")

        val wrong = runCatching { NetworkSources.test(context, null, config("host" to host, "share" to share, "user" to user, "password" to "zle")) }
        assertEquals("Nieprawidłowy użytkownik lub hasło.", wrong.exceptionOrNull()?.message)

        val good = config("host" to host, "share" to share, "user" to user, "password" to password)
        val folders = NetworkSources.test(context, null, good).getJSONArray("folders")
        assertTrue(folders.toString(), (0 until folders.length()).any { folders.getString(it) == "Polskie ąę albumy" })

        val id = catalog.saveSmb(null, good)
        catalog.cancelled.set(false)
        val first = catalog.scan(id, progress = ::noop)
        assertEquals(first.toString(), 2, first.getInt("added"))
        assertEquals(0, first.getJSONArray("errors").length())
        val second = catalog.scan(id, progress = ::noop)
        assertEquals("unchanged files are not read again", 2, second.getInt("unchanged"))

        val flac = File("../../test/fixtures/sample.flac").readBytes()
        val track = sha(flac)
        val uri = catalog.uri(track)
        assertEquals("smb", uri.scheme)
        assertEquals(id, uri.authority)

        // Playback reads from any offset (seek) without downloading the whole file first.
        val source = SmbDataSource(context)
        val offset = 4000L
        val length = source.open(DataSpec.Builder().setUri(uri).setPosition(offset).build())
        assertEquals(flac.size - offset, length)
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(3000)
        while (true) {
            val n = source.read(buffer, 0, buffer.size)
            if (n == C.RESULT_END_OF_INPUT) break
            out.write(buffer, 0, n)
        }
        source.close()
        assertArrayEquals(flac.copyOfRange(offset.toInt(), flac.size), out.toByteArray())

        // Dropped session (sleep, Wi-Fi change): the next read logs in again.
        Smb.close(id)
        val again = SmbDataSource(context)
        assertEquals(flac.size.toLong(), again.open(DataSpec(uri)))
        again.close()

        // Unreachable share keeps everything, reachable again restores playback.
        assertTrue(catalog.setReachable(id, false))
        assertFalse(catalog.track(track).getBoolean("available"))
        NetworkSources.probe(context)
        assertTrue(catalog.track(track).getBoolean("available"))
        catalog.forget(id)
    }
}
