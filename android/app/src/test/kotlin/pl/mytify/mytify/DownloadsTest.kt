package pl.mytify.mytify

import android.content.Context
import java.io.File
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
class DownloadsTest {
    private lateinit var context: Context
    private lateinit var catalog: Catalog

    @Before
    fun setup() {
        context = RuntimeEnvironment.getApplication()
        context.deleteDatabase("catalog-android.sqlite3")
        Secrets.memory = mutableMapOf()
        catalog = Catalog(context)
        NetworkSources.shared = catalog
        Downloads.assumeNetwork = true
    }

    @After
    fun cleanup() {
        Downloads.assumeNetwork = null
        NetworkSources.shared = null
        catalog.close()
        Secrets.memory = null
    }

    private fun noop(done: Int, total: Int, name: String) {}

    private fun tracks() = catalog.load().let { a -> (0 until a.length()).map { a.getJSONObject(it) } }

    /** Downloads from the real WebDAV and Samba servers started by CI. */
    @Test
    fun downloadIsALocationVerifiedAndRemovable() {
        val url = System.getenv("MYTIFY_DAV_URL")
        assumeTrue("MYTIFY_DAV_URL not set", url != null)
        val dav = catalog.saveNetwork(null, obj("protocol" to "webdav", "url" to url, "user" to "mat", "password" to System.getenv("MYTIFY_DAV_PASSWORD")))
        catalog.cancelled.set(false)
        catalog.scan(dav, progress = ::noop)
        System.getenv("MYTIFY_SMB_HOST")?.let { host ->
            val smb = catalog.saveNetwork(null, obj("protocol" to "smb", "host" to host, "share" to System.getenv("MYTIFY_SMB_SHARE"), "user" to System.getenv("MYTIFY_SMB_USER"), "password" to System.getenv("MYTIFY_SMB_PASSWORD")))
            catalog.scan(smb, progress = ::noop)
        }
        val before = tracks()
        val ids = before.map { it.getString("id") }
        assertTrue(before.all { it.getBoolean("remote") && !it.getBoolean("offline") })
        val d = Downloads(context, catalog)
        d.cellular = false
        val estimate = d.estimate(ids)
        assertEquals(before.size, estimate.getInt("count"))
        assertTrue(estimate.getLong("bytes") > 0)

        // Garbage of an older file version must not be continued.
        val flac = before.first { it.getString("format") == "FLAC" }.getString("id")
        File(d.dir, "$flac.flac.part").writeText("old bytes")
        File(d.dir, "$flac.flac.part.json").writeText("12345")

        assertEquals(before.size, d.add(ids, "user"))
        d.runQueue {}
        assertEquals(0, d.status().getJSONArray("items").length())
        val after = tracks()
        assertEquals("no second track", before.size, after.size)
        assertTrue(after.all { it.getBoolean("offline") })
        val local = catalog.uri(flac)
        assertEquals("file", local.scheme)
        assertArrayEquals(File("../../test/fixtures/sample.flac").readBytes(), File(local.path!!).readBytes())

        // Airplane mode / NAS gone: the copy still plays.
        catalog.sourceList().let { a -> (0 until a.length()).map { a.getJSONObject(it) } }
            .filter { it.getString("protocol") != "local" }
            .forEach { catalog.setReachable(it.getString("id"), false) }
        assertEquals("file", catalog.uri(flac).scheme)

        // "Usuń pobranie" keeps the track and its NAS location.
        d.remove(listOf(flac))
        val t = catalog.track(flac)
        assertFalse(t.getBoolean("offline"))
        assertTrue(t.getInt("locationCount") >= 1)
        assertFalse(File(local.path!!).exists())
    }

    @Test
    fun keptPlaylistFollowsNewEntries() {
        val url = System.getenv("MYTIFY_DAV_URL")
        assumeTrue("MYTIFY_DAV_URL not set", url != null)
        val dav = catalog.saveNetwork(null, obj("protocol" to "webdav", "url" to url, "user" to "mat", "password" to System.getenv("MYTIFY_DAV_PASSWORD")))
        catalog.cancelled.set(false)
        catalog.scan(dav, progress = ::noop)
        val ids = tracks().map { it.getString("id") }
        val store = PlaylistStore(catalog)
        val playlist = store.save(null, "W drogę", ids.take(1))
        val d = Downloads(context, catalog)
        d.keep(playlist, true)
        d.runQueue {}
        assertEquals(1, tracks().count { it.getBoolean("offline") })
        store.save(playlist, "W drogę", ids)
        d.refreshKept()
        d.runQueue {}
        assertEquals(ids.size, tracks().count { it.getBoolean("offline") })
        // Turning it off removes only copies the playlist asked for.
        d.add(ids.take(1), "user")
        d.keep(playlist, false)
        assertEquals(1, tracks().count { it.getBoolean("offline") })
    }
}
