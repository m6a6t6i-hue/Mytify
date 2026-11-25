package pl.mytify.mytify

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.DataSpec
import java.io.File
import okhttp3.HttpUrl.Companion.toHttpUrl
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
class WebDavTest {
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

    private fun config(vararg f: Pair<String, Any?>) = obj("protocol" to "webdav", *f)

    private fun noop(done: Int, total: Int, name: String) {}

    @Test
    fun settingsRequireHttpsAndKeepPolishFolders() {
        val s = DavSettings.parse(config("url" to "nas.example.com:5006/muzyka", "folder" to "Polskie ąę/Jazz"))
        assertEquals("https://nas.example.com:5006/muzyka/", s.url)
        assertEquals("https://nas.example.com:5006/muzyka/Polskie%20%C4%85%C4%99/Jazz/", s.root().toString())
        assertEquals("Jazz", s.name)
        assertThrows(IllegalArgumentException::class.java) { DavSettings.parse(config("url" to "http://nas/m")) }
        assertThrows(IllegalArgumentException::class.java) { DavSettings.parse(config("url" to "https://mat:x@nas/m")) }
        assertEquals("https://nas/", DavSettings.parse(config("url" to "https://nas")).root().toString())
    }

    @Test
    fun listingIgnoresOtherHostsAndParentFolder() {
        val folder = "https://nas/dav/music/".toHttpUrl()
        val xml =
            """<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
            <d:response><d:href>/dav/music/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            <d:response><d:href>/dav/music/Za%C5%BC%C3%B3%C5%82%C4%87/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            <d:response><d:href>/dav/music/01%20Utw%C3%B3r.flac</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>1234</d:getcontentlength><d:getetag>"abc"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            <d:response><d:href>https://evil.example/x.flac</d:href><d:propstat><d:prop><d:getcontentlength>1</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            </d:multistatus>"""
        val e = WebDav.parse(xml, folder)
        assertEquals(2, e.size)
        assertTrue(e[0].dir)
        assertEquals("Zażółć", e[0].name)
        assertEquals("01 Utwór.flac", e[1].name)
        assertEquals(1234L, e[1].size)
        assertEquals("/dav/music/01%20Utw%C3%B3r.flac", e[1].href)
        assertEquals("/dav/music/01%20Utw%C3%B3r.flac", WebDav.uri("id", e[1].href).encodedPath)
    }

    /** Real HTTPS WebDAV servers, started by CI (tools/dav_test_server.py). */
    @Test
    fun realServerScanPlaySeek() {
        val url = System.getenv("MYTIFY_DAV_URL")
        assumeTrue("MYTIFY_DAV_URL not set", url != null)
        val password = System.getenv("MYTIFY_DAV_PASSWORD")

        val wrong = runCatching { NetworkSources.test(context, null, config("url" to url, "user" to "mat", "password" to "zle")) }
        assertEquals("Nieprawidłowy użytkownik lub hasło.", wrong.exceptionOrNull()?.message)
        System.getenv("MYTIFY_DAV_UNTRUSTED_URL")?.let { untrusted ->
            val e = runCatching { NetworkSources.test(context, null, config("url" to untrusted, "user" to "mat", "password" to password)) }
            assertTrue(e.exceptionOrNull()?.message, e.exceptionOrNull()?.message!!.startsWith("Certyfikat serwera nie jest zaufany"))
        }
        val good = config("url" to url, "user" to "mat", "password" to password)
        assertEquals("[\"Polskie ąę albumy\"]", NetworkSources.test(context, null, good).getJSONArray("folders").toString())

        val id = catalog.saveNetwork(null, good)
        catalog.cancelled.set(false)
        val first = catalog.scan(id, progress = ::noop)
        assertEquals(first.toString(), 2, first.getInt("added"))
        assertEquals(2, catalog.scan(id, progress = ::noop).getInt("unchanged"))

        val flac = File("../../test/fixtures/sample.flac").readBytes()
        val tracks = catalog.load()
        val track = (0 until tracks.length()).map { tracks.getJSONObject(it) }.first { it.getString("fileName") == "a.flac" }
        val uri = catalog.uri(track.getString("id"))
        assertEquals("dav", uri.scheme)
        assertFalse("no password in the location", uri.toString().contains(password))

        val source = RoutingDataSource(context)
        val offset = 6000L
        source.open(DataSpec.Builder().setUri(uri).setPosition(offset).build())
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val n = source.read(buffer, 0, buffer.size)
            if (n == C.RESULT_END_OF_INPUT) break
            out.write(buffer, 0, n)
        }
        source.close()
        assertArrayEquals(flac.copyOfRange(offset.toInt(), flac.size), out.toByteArray())

        assertTrue(catalog.setReachable(id, false))
        assertFalse(catalog.track(track.getString("id")).getBoolean("available"))
        NetworkSources.probe(context)
        assertTrue(catalog.track(track.getString("id")).getBoolean("available"))
        catalog.forget(id)
        assertNull(Secrets.load(context, id))
    }

    @Test
    fun serverWithoutRangesFallsBackToOneDownload() {
        val url = System.getenv("MYTIFY_NORANGE_URL")
        assumeTrue("MYTIFY_NORANGE_URL not set", url != null)
        val s = DavSettings.parse(config("url" to url))
        val flac = File("../../test/fixtures/sample.flac").readBytes()
        val cache = File(context.cacheDir, "norange-test")
        val src = DavMediaDataSource(s, "", s.root().resolve("Polskie%20%C4%85%C4%99%20albumy/a.flac")!!, flac.size.toLong(), cache)
        val part = ByteArray(100)
        assertEquals(100, src.readAt(7000, part, 0, 100))
        assertArrayEquals(flac.copyOfRange(7000, 7100), part)
        assertTrue(cache.isFile)
        src.close()
        assertFalse(cache.exists())
    }
}
