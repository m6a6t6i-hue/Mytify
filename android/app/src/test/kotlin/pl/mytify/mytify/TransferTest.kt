package pl.mytify.mytify

import java.io.File
import java.net.Proxy
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class TransferTest {
    @Test
    fun qrRejectsInternetMetadataAndAmbiguousAddresses() {
        val pin = "a".repeat(64)
        val secret = "b".repeat(64)
        fun link(h: String) = "mytify://pair?v=1&host=$h&port=47479&fingerprint=$pin&secret=$secret"
        assertEquals("192.168.1.9", TransferPeer.parse(link("192.168.1.9")).first.host)
        for (host in
            listOf(
                "169.254.169.254",
                "127.0.0.1",
                "8.8.8.8",
                "example.org",
                "192.168.001.9",
                "192.168.1.300",
            )) assertThrows(IllegalArgumentException::class.java) { TransferPeer.parse(link(host)) }
        assertThrows(IllegalArgumentException::class.java) {
            TransferPeer.parse(link("192.168.1.9").replace("mytify://", "https://"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            TransferPeer.parse(link("192.168.1.9").replace(pin, "short"))
        }
    }

    @Test
    fun offlineCatalogPreservesPhoneEditsAndRescansPrivateCopies() {
        val c = RuntimeEnvironment.getApplication()
        c.deleteDatabase("catalog-android.sqlite3")
        val catalog = Catalog(c)
        val root = File(c.filesDir, "offline-music").apply { mkdirs() }
        val file = File(root, "test.flac").apply { writeBytes(byteArrayOf(1, 2, 3, 4)) }
        val id = TransferClient.fileHash(file)
        val peer = "c".repeat(64)
        val t =
            obj(
                "id" to id,
                "title" to "Tytuł z PC",
                "artist" to "Łódź",
                "album" to "Album",
                "albumArtist" to "Łódź",
                "fileName" to "oryginal.flac",
                "format" to "FLAC",
                "size" to 4,
                "liked" to true,
            )
        catalog.registerOffline(peer, "PC", t, file, null)
        assertEquals("Tytuł z PC", catalog.track(id).getString("title"))
        assertEquals("file", catalog.uri(id).scheme)
        catalog.edit(
            org.json.JSONArray().put(obj("id" to id, "patch" to obj("title" to "Moja zmiana")))
        )
        catalog.like(id, false)
        catalog.registerOffline(peer, "PC", t, file, null)
        assertEquals("Moja zmiana", catalog.track(id).getString("title"))
        assertFalse(catalog.track(id).getBoolean("liked"))
        assertEquals(1, catalog.load().length())
        catalog.cancelled.set(false)
        catalog.scan("offline:$peer", progress = { _, _, _ -> })
        assertTrue(catalog.track(id).getBoolean("available"))
        catalog.reset(listOf(id))
        assertEquals("oryginal", catalog.track(id).getString("title"))
        catalog.remove(id)
        assertTrue(file.exists())
        catalog.deleteOffline(peer)
        assertFalse(file.exists())
        assertEquals(0, catalog.load().length())
        catalog.close()
    }

    @Test
    fun discardRemovesOnlyPartialFiles() {
        val c = RuntimeEnvironment.getApplication()
        val root = File(c.filesDir, "offline-music").apply { mkdirs() }
        val id = "a".repeat(64)
        val part = File(root, "$id.part").apply { writeText("partial") }
        val complete = File(root, "$id.flac").apply { writeText("completed") }
        val f = android.util.AtomicFile(File(c.filesDir, "transfer-job.json"))
        f.startWrite().also {
            it.write(
                obj(
                        "state" to "paused",
                        "peer" to "b".repeat(64),
                        "tracks" to org.json.JSONArray().put(obj("id" to id)),
                    )
                    .toString()
                    .toByteArray()
            )
            f.finishWrite(it)
        }
        val store =
            object : TransferPeers {
                override fun list() = emptyList<TransferPeer>()

                override fun save(peers: List<TransferPeer>) {}
            }
        val manager = TransferManager(c, store)
        manager.discard()
        assertFalse(part.exists())
        assertTrue(complete.exists())
        assertEquals("idle", manager.status().getString("state"))
        complete.delete()
    }

    @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    @Test
    fun realTlsResumeChecksumDedupeAndOfflineAfterPcStops() {
        val path = System.getenv("MYTIFY_TRANSFER_E2E")
        org.junit.Assume.assumeTrue(
            "Real PC fixture is provided by tools/transfer_e2e.py",
            !path.isNullOrEmpty(),
        )
        val fixture = JSONObject(File(path!!).readText())
        val link = fixture.getString("link")
        val png = java.util.Base64.getDecoder().decode(fixture.getString("qr"))
        val image = android.graphics.BitmapFactory.decodeByteArray(png, 0, png.size)
        val pixels = IntArray(image.width * image.height)
        image.getPixels(pixels, 0, image.width, 0, 0, image.width, image.height)
        val luminance = com.google.zxing.RGBLuminanceSource(image.width, image.height, pixels)
        assertEquals(
            link,
            com.google.zxing
                .MultiFormatReader()
                .decode(
                    com.google.zxing.BinaryBitmap(
                        com.google.zxing.common.HybridBinarizer(luminance)
                    )
                )
                .text,
        )
        val parsed = TransferPeer.parse(link, true)
        assertThrows(Exception::class.java) {
            TransferClient(true).pair(link.replace(parsed.first.pin, "0".repeat(64)))
        }
        val context = RuntimeEnvironment.getApplication()
        context.deleteDatabase("catalog-android.sqlite3")
        File(context.filesDir, "offline-music").deleteRecursively()
        File(context.filesDir, "transfer-job.json").delete()
        val store =
            object : TransferPeers {
                var values = emptyList<TransferPeer>()

                override fun list() = values

                override fun save(peers: List<TransferPeer>) {
                    values = peers
                }
            }
        var manager = TransferManager(context, store, TransferClient(true))
        manager.pair(link)
        val peer = store.values.single()
        val m = manager.manifest(peer.pin)
        val tracks = m.getJSONArray("tracks")
        val ids = (0 until tracks.length()).map { tracks.getJSONObject(it).getString("id") }
        assertEquals(4, ids.size)
        manager.prepare(peer.pin, ids, emptyList())
        manager.onProgress = { if (manager.status().optLong("doneBytes") > 0) manager.pause() }
        manager.runJob()
        assertEquals("paused", manager.status().getString("state"))
        val catalog = Catalog(context)
        assertEquals(0, catalog.load().length())
        // Simulate a shorter durable prefix after a process/power interruption, then use real HTTP
        // Range.
        val firstPart = File(context.filesDir, "offline-music/${ids[0]}.part")
        assertTrue(firstPart.isFile)
        java.io.RandomAccessFile(firstPart, "rw").use {
            it.setLength(minOf(8000, firstPart.length()))
        }
        manager.onProgress = null
        manager = TransferManager(context, store, TransferClient(true))
        assertEquals("paused", manager.status().getString("state"))
        manager.reserveResume()
        manager.runJob()
        assertEquals(manager.status().toString(), "complete", manager.status().getString("state"))
        assertEquals(4, catalog.load().length())
        val expected = fixture.getJSONObject("hashes")
        for (id in ids) {
            val uri = catalog.uri(id)
            assertEquals("file", uri.scheme)
            val bytes = context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
            assertEquals(id, sha(bytes))
            assertEquals(expected.getLong(id), bytes.size.toLong())
        }
        catalog.edit(
            org.json
                .JSONArray()
                .put(obj("id" to ids[0], "patch" to obj("title" to "Zmiana na telefonie")))
        )
        catalog.like(ids[0], false)
        val list = m.getJSONArray("playlists").getJSONObject(0)
        manager.prepare(peer.pin, ids, listOf(list.getString("id")))
        manager.runJob()
        assertEquals("complete", manager.status().getString("state"))
        assertEquals(4, catalog.load().length())
        assertEquals("Zmiana na telefonie", catalog.track(ids[0]).getString("title"))
        assertFalse(catalog.track(ids[0]).getBoolean("liked"))
        assertEquals(1, PlaylistStore(catalog).list().length())
        // Corrupt prefix must never be accepted as a completed file.
        val t = tracks.getJSONObject(0)
        val bad = File(context.cacheDir, "corrupt.part").apply { writeBytes(ByteArray(100) { 7 }) }
        assertThrows(Exception::class.java) {
            TransferClient().download(
                peer,
                t.getString("id"),
                t.getLong("size"),
                bad,
                AtomicBoolean(false),
            ) {}
        }
        assertFalse(bad.exists())
        val control =
            URL(fixture.getString("base") + "/api/transfer").openConnection(Proxy.NO_PROXY)
                as java.net.HttpURLConnection
        control.requestMethod = "POST"
        control.setRequestProperty("X-Mytify-Token", fixture.getString("token"))
        control.doOutput = true
        control.outputStream.use { it.write("{\"action\":\"stop\"}".toByteArray()) }
        assertEquals(200, control.responseCode)
        control.inputStream.close()
        control.disconnect()
        File(fixture.getString("stopRequest")).writeText("stop")
        val ack = File(fixture.getString("stopAck"))
        val deadline = System.currentTimeMillis() + 10000
        while (!ack.exists() && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertTrue("PC process must be stopped", ack.exists())
        assertThrows(Exception::class.java) { TransferClient().json(peer, "/manifest") }
        for (id in ids) {
            val uri = catalog.uri(id)
            assertEquals(
                id,
                context.contentResolver.openInputStream(uri)!!.use { sha(it.readBytes()) },
            )
        }
        manager.deleteCopies(peer.pin)
        assertEquals(0, catalog.load().length())
        catalog.close()
    }
}
