package pl.mytify.mytify

import androidx.media3.exoplayer.audio.AudioSink
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EqualizerTest {
    @After
    fun off() = Equalizer.set(false, emptyList(), null)

    /** Like DefaultAudioSink: takes half a buffer per call and rejects a different buffer while one is pending. */
    private class SlowSink {
        var pending: ByteBuffer? = null
        var calls = 0
        val sink: AudioSink =
            Proxy.newProxyInstance(AudioSink::class.java.classLoader, arrayOf(AudioSink::class.java)) { _, m, args ->
                when {
                    m.name == "handleBuffer" -> {
                        val b = args[0] as ByteBuffer
                        require(pending == null || pending === b) { "different buffer while pending" }
                        pending = b
                        calls++
                        val take = maxOf(4, b.remaining() / 2 / 4 * 4)
                        b.position(minOf(b.limit(), b.position() + take))
                        val done = !b.hasRemaining()
                        if (done) pending = null
                        done
                    }
                    m.returnType == Boolean::class.javaPrimitiveType -> false
                    m.returnType == Long::class.javaPrimitiveType -> 0L
                    m.returnType == Int::class.javaPrimitiveType -> 0
                    m.returnType == Float::class.javaPrimitiveType -> 0f
                    else -> null
                }
            } as AudioSink
    }

    private fun eqSink(slow: SlowSink): EqSink {
        val s = EqSink(slow.sink)
        EqSink::class.java.getDeclaredField("filter").apply { isAccessible = true }.set(s, EqFilter(44100, 2))
        return s
    }

    private fun pcm(frames: Int): ByteBuffer {
        val b = ByteBuffer.allocateDirect(frames * 4).order(ByteOrder.nativeOrder())
        repeat(frames * 2) { b.putShort(((it * 37) % 2000 - 1000).toShort()) }
        b.flip()
        return b
    }

    @Test
    fun switchingPresetMidBufferKeepsTheSameBuffer() {
        for (start in listOf(false, true)) {
            Equalizer.set(start, List(10) { 6f }, null)
            val slow = SlowSink()
            val sink = eqSink(slow)
            val buffer = pcm(1024)
            var toggles = 0
            while (!sink.handleBuffer(buffer, 0, 1)) {
                // A preset change lands between two calls for the same buffer.
                toggles++
                Equalizer.set(!Equalizer.enabled, List(10) { 6f }, null)
            }
            assertTrue(toggles > 0)
            assertEquals(0, buffer.remaining())
            // The next buffer is decided afresh and also completes.
            val next = pcm(256)
            while (!sink.handleBuffer(next, 0, 1)) Unit
            assertEquals(0, next.remaining())
        }
    }
}
