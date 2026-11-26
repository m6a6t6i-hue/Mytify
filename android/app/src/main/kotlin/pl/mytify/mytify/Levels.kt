package pl.mytify.mytify

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Keeps a copy of the decoded sound on its way to the speaker, so the seek bar and the
 * full screen visualizations can show real levels of what is heard now. The audio itself
 * passes through untouched. Positions come from the sink, so the picture follows the
 * speaker, not the decoder that runs ahead of it.
 */
@OptIn(UnstableApi::class)
class LevelSink(sink: AudioSink) : ForwardingAudioSink(sink) {
    private val lock = Any()
    private val ring = FloatArray(RING)
    private var head = 0L
    private val chunkTime = LongArray(CHUNKS)
    private val chunkStart = LongArray(CHUNKS)
    private var chunks = 0L
    private var encoding = C.ENCODING_PCM_16BIT
    private var channels = 2
    private var rate = 44100
    private var lastUs = Long.MIN_VALUE

    @Volatile private var playedUs = Long.MIN_VALUE
    @Volatile private var playedAt = 0L

    private fun clearLevels() {
        head = 0
        chunks = 0
        lastUs = Long.MIN_VALUE
        playedUs = Long.MIN_VALUE
    }

    override fun configure(audioSinkConfig: AudioSink.AudioSinkConfig) {
        val inputFormat: Format = audioSinkConfig.format
        synchronized(lock) {
            encoding = inputFormat.pcmEncoding
            channels = max(1, inputFormat.channelCount)
            rate = max(1, inputFormat.sampleRate)
            clearLevels()
        }
        super.configure(audioSinkConfig)
    }

    override fun reset() {
        synchronized(lock) { clearLevels() }
        super.reset()
    }

    override fun flush() {
        synchronized(lock) { clearLevels() }
        super.flush()
    }

    override fun handleBuffer(buffer: ByteBuffer, presentationTimeUs: Long, encodedAccessUnitCount: Int): Boolean {
        // The renderer offers the same buffer again until the sink takes all of it.
        if (presentationTimeUs > lastUs) {
            runCatching { copy(buffer.duplicate().order(ByteOrder.nativeOrder()), presentationTimeUs) }
        }
        return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount)
    }

    override fun getCurrentPositionUs(sourceEnded: Boolean): Long {
        val p = super.getCurrentPositionUs(sourceEnded)
        if (p != AudioSink.CURRENT_POSITION_NOT_SET) {
            if (p != playedUs) playedAt = System.nanoTime()
            playedUs = p
        }
        return p
    }

    private fun copy(b: ByteBuffer, timeUs: Long) =
        synchronized(lock) {
            val bytes =
                when (encoding) {
                    C.ENCODING_PCM_16BIT -> 2
                    C.ENCODING_PCM_24BIT -> 3
                    C.ENCODING_PCM_32BIT, C.ENCODING_PCM_FLOAT -> 4
                    C.ENCODING_PCM_8BIT -> 1
                    else -> return@synchronized
                }
            val frames = b.remaining() / (bytes * channels)
            if (frames <= 0) return@synchronized
            lastUs = timeUs
            val slot = (chunks % CHUNKS).toInt()
            chunkTime[slot] = timeUs
            chunkStart[slot] = head
            chunks++
            var at = b.position()
            for (f in 0 until frames) {
                var sum = 0f
                for (c in 0 until channels) {
                    sum +=
                        when (encoding) {
                            C.ENCODING_PCM_16BIT -> b.getShort(at) / 32768f
                            C.ENCODING_PCM_24BIT -> {
                                val v =
                                    (b.get(at).toInt() and 0xff) or
                                        ((b.get(at + 1).toInt() and 0xff) shl 8) or
                                        (b.get(at + 2).toInt() shl 16)
                                v / 8388608f
                            }
                            C.ENCODING_PCM_32BIT -> b.getInt(at) / 2147483648f
                            C.ENCODING_PCM_FLOAT -> b.getFloat(at)
                            else -> ((b.get(at).toInt() and 0xff) - 128) / 128f
                        }
                    at += bytes
                }
                ring[((head + f) % RING).toInt()] = sum / channels
            }
            head += frames
        }

    /** Band levels in dBFS of what is heard now; null when paused, stalled or not yet known. */
    fun bands(): DoubleArray? {
        val window = FloatArray(WINDOW)
        val sampleRate: Int
        synchronized(lock) {
            val played = playedUs
            if (played == Long.MIN_VALUE || chunks == 0L) return null
            if (System.nanoTime() - playedAt > 300_000_000L) return null
            // Newest chunk that started before the speaker position.
            var index = -1L
            val first = max(0L, chunks - CHUNKS)
            for (n in chunks - 1 downTo first) {
                val slot = (n % CHUNKS).toInt()
                if (chunkTime[slot] <= played) {
                    index = chunkStart[slot] + (played - chunkTime[slot]) * rate / 1_000_000L
                    break
                }
            }
            if (index < 0) return null
            index = min(index, head)
            if (index < WINDOW || head - index > RING - WINDOW) return null
            for (i in 0 until WINDOW) window[i] = ring[((index - WINDOW + i) % RING).toInt()]
            sampleRate = rate
        }
        return Spectrum.bands(window, sampleRate)
    }

    companion object {
        const val RING = 1 shl 17
        const val WINDOW = 2048
        const val CHUNKS = 512
    }
}

/** Same analysis as the PC engine (native/mytify_core/src/audio/spectrum.rs). */
object Spectrum {
    const val BANDS = 40
    private const val LOW_HZ = 45.0
    private const val HIGH_HZ = 16000.0

    fun bands(samples: FloatArray, rate: Int): DoubleArray {
        val n = samples.size
        val re = DoubleArray(n)
        val im = DoubleArray(n)
        for (i in 0 until n) {
            val w = 0.5 - 0.5 * cos(2 * Math.PI * i / (n - 1))
            val s = samples[i].toDouble()
            re[i] = if (s.isFinite()) s * w else 0.0
        }
        fft(re, im)
        val hz = rate.toDouble() / n
        val top = min(HIGH_HZ, rate * 0.45)
        val scale = 4.0 / n
        fun mag(k: Int) = sqrt(re[k] * re[k] + im[k] * im[k]) * scale
        return DoubleArray(BANDS) { b ->
            val lo = LOW_HZ * (top / LOW_HZ).pow(b.toDouble() / BANDS)
            val hi = LOW_HZ * (top / LOW_HZ).pow((b + 1).toDouble() / BANDS)
            val k0 = floor(lo / hz).toInt()
            val k1 = kotlin.math.ceil(hi / hz).toInt()
            val peak =
                if (k1 <= k0 + 1) {
                    val x = sqrt(lo * hi) / hz
                    val k = min(floor(x).toInt(), n / 2 - 2)
                    val f = x - k
                    mag(k) * (1 - f) + mag(k + 1) * f
                } else {
                    var m = 0.0
                    for (k in k0 until min(k1, n / 2)) m = max(m, mag(k))
                    m
                }
            val centre = sqrt(lo * hi)
            val db = 20 * log10(max(peak, 1e-7)) + 3 * (ln(centre / 1000.0) / ln(2.0))
            (db * 10).roundToInt() / 10.0
        }
    }

    private fun fft(re: DoubleArray, im: DoubleArray) {
        val n = re.size
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) {
                j = j xor bit
                bit = bit shr 1
            }
            j = j or bit
            if (i < j) {
                var t = re[i]; re[i] = re[j]; re[j] = t
                t = im[i]; im[i] = im[j]; im[j] = t
            }
        }
        var len = 2
        while (len <= n) {
            val a = -2 * Math.PI / len
            for (i in 0 until n step len) {
                for (k in 0 until len / 2) {
                    val c = cos(a * k)
                    val s = sin(a * k)
                    val u = i + k
                    val v = i + k + len / 2
                    val tr = re[v] * c - im[v] * s
                    val ti = re[v] * s + im[v] * c
                    re[v] = re[u] - tr
                    im[v] = im[u] - ti
                    re[u] += tr
                    im[u] += ti
                }
            }
            len = len shl 1
        }
    }
}
