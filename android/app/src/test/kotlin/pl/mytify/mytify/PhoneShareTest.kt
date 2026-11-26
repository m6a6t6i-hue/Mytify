package pl.mytify.mytify

import android.content.ContentValues
import java.io.File
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
class PhoneShareTest {
    private class Memory : ShareStore {
        var value: JSONObject? = null

        override fun load() = value?.let { JSONObject(it.toString()) }

        override fun save(value: JSONObject) {
            this.value = JSONObject(value.toString())
        }
    }

    @Test
    fun selfSignedCertificateIsValidEcdsa() {
        val (cert, key) = SelfSigned.create()
        cert.checkValidity()
        cert.verify(cert.publicKey)
        assertEquals("EC", key.algorithm)
        assertTrue(cert.subjectX500Principal.name.contains("mytify.local"))
    }

    @Test
    fun anotherPhonePairsOnceListsAndDownloadsOverPinnedTls() {
        val context = RuntimeEnvironment.getApplication()
        context.deleteDatabase("catalog-android.sqlite3")
        val bytes = ByteArray(300_000) { (it * 31 % 251).toByte() }
        val id = sha(bytes)
        val file = File(context.filesDir, "song.mp3").apply { writeBytes(bytes) }
        val catalog = Catalog(context)
        catalog.writableDatabase.insert(
            "tracks",
            null,
            ContentValues().apply {
                put("id", id)
                put("raw", obj("title" to "Piosenka", "artist" to "Zespół", "album" to "Płyta", "fileName" to "song.mp3", "format" to "mp3", "size" to bytes.size).toString())
                put("added", 1L)
            },
        )
        catalog.writableDatabase.insert(
            "locations",
            null,
            ContentValues().apply {
                put("uri", android.net.Uri.fromFile(file).toString())
                put("source", "s")
                put("track", id)
                put("name", "song.mp3")
            },
        )
        val store = Memory()
        val share = PhoneShare(context, store, allowLoopback = true)
        share.start("127.0.0.1".takeIf { it in share.addresses() } ?: share.addresses().first(), 0)
        try {
            val link = share.status().getString("pairUri")
            val client = TransferClient(true)
            val peer = client.pair(link)
            assertEquals(share.fingerprint(), peer.pin)
            // The code works once.
            assertThrows(Exception::class.java) { client.pair(link) }
            assertTrue(share.status().isNull("pairUri"))
            val m = client.json(peer, "/manifest")
            val t = m.getJSONArray("tracks").getJSONObject(0)
            assertEquals(id, t.getString("id"))
            assertEquals("Piosenka", t.getString("title"))
            val part = File(context.cacheDir, "$id.part").apply { delete() }
            client.download(peer, id, bytes.size.toLong(), part, AtomicBoolean(false)) {}
            assertArrayEquals(bytes, part.readBytes())
            // Resume with Range from the middle.
            java.io.RandomAccessFile(part, "rw").use { it.setLength(100_000) }
            client.download(peer, id, bytes.size.toLong(), part, AtomicBoolean(false)) {}
            assertArrayEquals(bytes, part.readBytes())
            // A revoked phone gets nothing.
            share.command(obj("action" to "revoke", "id" to share.status().getJSONArray("peers").getJSONObject(0).getString("id")))
            assertThrows(Exception::class.java) { client.json(peer, "/manifest") }
            // The identity survives a restart: same pin from the store.
            assertEquals(share.fingerprint(), PhoneShare(context, store, true).fingerprint())
        } finally {
            share.stop()
        }
    }
}
