package pl.mytify.mytify

import android.content.Context
import androidx.media3.common.C
import androidx.media3.datasource.DataSpec
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
class SubsonicTest {
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

    private fun noop(done: Int, total: Int, name: String) {}

    @Test
    fun settingsNormaliseAddressAndKeepQualityOff() {
        val s = ServerSettings.parse(obj("url" to "http://192.168.1.5:4533/app/", "user" to "mat"))
        assertEquals("http://192.168.1.5:4533/", s.url)
        assertEquals("original", s.qualityWifi)
        assertEquals("original", s.qualityMobile)
        assertEquals("https://nas/navidrome/", ServerSettings.parse(obj("url" to "nas/navidrome/rest", "user" to "m")).url)
        assertThrows(IllegalArgumentException::class.java) { ServerSettings.parse(obj("url" to "https://nas", "user" to "")) }
        val mp3 = SubsonicClient.Song.parse(obj("id" to "1", "title" to "A", "suffix" to "mp3", "bitDepth" to 16))!!
        assertEquals("no PCM bit depth for MP3", 0, mp3.pcmDepth)
    }

    /** Real Navidrome, started by CI. */
    @Test
    fun navidromeLibraryLikesPlaysPlaylists() {
        val url = System.getenv("MYTIFY_SUBSONIC_URL")
        assumeTrue("MYTIFY_SUBSONIC_URL not set", url != null)
        val user = System.getenv("MYTIFY_SUBSONIC_USER")
        val password = System.getenv("MYTIFY_SUBSONIC_PASSWORD")
        fun config(p: String) = obj("protocol" to "subsonic", "url" to url, "user" to user, "password" to p)

        val wrong = runCatching { NetworkSources.test(context, null, config("zle")) }
        assertEquals("Nieprawidłowy użytkownik lub hasło.", wrong.exceptionOrNull()?.message)
        val message = NetworkSources.test(context, null, config(password)).getString("message")
        assertTrue(message, message.lowercase().contains("navidrome"))

        val id = catalog.saveNetwork(null, config(password))
        catalog.cancelled.set(false)
        val first = catalog.scan(id, progress = ::noop)
        assertEquals(first.toString(), 2, first.getInt("added"))
        assertEquals(2, catalog.scan(id, progress = ::noop).getInt("unchanged"))

        val all = catalog.load()
        val tracks = (0 until all.length()).map { all.getJSONObject(it) }
        val flac = tracks.first { it.getString("format") == "FLAC" }
        val mp3 = tracks.first { it.getString("format") == "MP3" }
        assertEquals(0, mp3.getInt("bitDepth"))

        // Original stream from any offset.
        val bytes = File("../../test/fixtures/sample.flac").readBytes()
        val uri = catalog.uri(flac.getString("id"))
        assertEquals("subsonic", uri.scheme)
        val source = RoutingDataSource(context)
        source.open(DataSpec.Builder().setUri(uri).setPosition(2000).build())
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val n = source.read(buffer, 0, buffer.size)
            if (n == C.RESULT_END_OF_INPUT) break
            out.write(buffer, 0, n)
        }
        source.close()
        assertArrayEquals(bytes.copyOfRange(2000, bytes.size), out.toByteArray())

        // Favourites both ways, without overwriting a waiting local change.
        val client = catalog.server(id)
        catalog.like(flac.getString("id"), true)
        assertEquals(1, catalog.flushPending(id))
        val starred = client.call("getStarred2").getJSONObject("starred2").getJSONArray("song")
        assertEquals(1, starred.length())
        client.star(starred.getJSONObject(0).getString("id"), false)
        catalog.scan(id, progress = ::noop)
        assertFalse(catalog.track(flac.getString("id")).getBoolean("liked"))
        catalog.like(mp3.getString("id"), true)
        val songs = client.songs(0, 10).map { it.id }
        // The waiting local change is sent before the server state is read: it survives the rescan.
        catalog.scan(id, progress = ::noop)
        assertTrue(catalog.track(mp3.getString("id")).getBoolean("liked"))

        catalog.played(flac.getString("id"))
        catalog.flushPending(id)
        assertEquals(0, catalog.readableDatabase.rawQuery("SELECT id FROM pending_sync", null).use { it.count })

        // Playlists: import, local edit sent, both edited -> copy.
        val remote = client.savePlaylist(null, "Na drogę", songs.take(1))
        assertEquals(1, catalog.syncPlaylists(id).imported)
        val store = PlaylistStore(catalog)
        val local = (0 until store.list().length()).map { store.list().getJSONObject(it) }.first { it.getString("name") == "Na drogę" }
        store.save(local.getString("id"), "Na drogę", listOf(flac.getString("id"), mp3.getString("id")))
        assertEquals(1, catalog.syncPlaylists(id).sent)
        assertEquals(2, client.call("getPlaylist", listOf("id" to remote)).getJSONObject("playlist").getInt("songCount"))
        client.savePlaylist(remote, "Na drogę", songs.take(1))
        store.save(local.getString("id"), "Na drogę", listOf(mp3.getString("id")))
        assertEquals(1, catalog.syncPlaylists(id).conflicts)
        assertEquals(listOf(mp3.getString("id")), store.ids(local.getString("id")))
        val names = (0 until store.list().length()).map { store.list().getJSONObject(it).getString("name") }
        assertTrue(names.toString(), "Na drogę (z serwera)" in names)
        client.call("deletePlaylist", listOf("id" to remote))
        catalog.forget(id)
    }
}
