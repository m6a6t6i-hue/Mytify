package pl.mytify.mytify

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.sin
import org.json.JSONArray
import org.json.JSONObject

/** 10-band graphic equalizer, same bands and filters as the PC engine. */
object Equalizer {
    val BANDS = floatArrayOf(31f, 62f, 125f, 250f, 500f, 1000f, 2000f, 4000f, 8000f, 16000f)
    const val MAX_DB = 12f

    @Volatile var enabled = false
        private set
    @Volatile var gains = FloatArray(10)
        private set
    @Volatile var version = 1L
        private set

    fun load(context: Context) {
        val p = context.getSharedPreferences("player", 0)
        val list = p.getString("eqGains", null)?.split(',')?.mapNotNull { it.toFloatOrNull() }.orEmpty()
        set(p.getBoolean("eqEnabled", false), list, null)
    }

    fun set(on: Boolean, values: List<Float>, context: Context?) {
        val g = FloatArray(10) { i -> values.getOrNull(i)?.takeIf { it.isFinite() }?.coerceIn(-MAX_DB, MAX_DB) ?: 0f }
        gains = g
        enabled = on
        version++
        context?.getSharedPreferences("player", 0)?.edit()
            ?.putBoolean("eqEnabled", on)
            ?.putString("eqGains", g.joinToString(","))
            ?.apply()
    }

    fun json(): JSONObject =
        JSONObject().put("enabled", enabled).put("gains", JSONArray(gains.map { it.toDouble() }))
}

/** Peaking biquads (RBJ, Q about one octave) with a preamp that keeps boosts from clipping. */
class EqFilter(private val rate: Int, private val channels: Int) {
    private var version = 0L
    var active = false
        private set
    private var preamp = 1f
    private val on = BooleanArray(10)
    private val c = Array(10) { FloatArray(5) }
    private val z = Array(10) { Array(max(1, channels)) { FloatArray(2) } }

    fun update() {
        if (version == Equalizer.version) return
        version = Equalizer.version
        val enabled = Equalizer.enabled
        val gains = Equalizer.gains
        var peak = 0f
        var any = false
        for (i in 0 until 10) {
            val db = gains[i]
            val f = Equalizer.BANDS[i]
            val use = enabled && abs(db) > 0.05f && f < rate * 0.45f
            if (use) {
                val a = 10.0.pow(db / 40.0)
                val w = 2 * PI * f / rate
                val alpha = sin(w) / (2 * 1.41)
                val a0 = 1 + alpha / a
                c[i][0] = ((1 + alpha * a) / a0).toFloat()
                c[i][1] = (-2 * cos(w) / a0).toFloat()
                c[i][2] = ((1 - alpha * a) / a0).toFloat()
                c[i][3] = (-2 * cos(w) / a0).toFloat()
                c[i][4] = ((1 - alpha / a) / a0).toFloat()
                peak = max(peak, db)
                any = true
            } else if (on[i]) {
                z[i].forEach { it.fill(0f) }
            }
            on[i] = use
        }
        active = any
        preamp = 10.0.pow(-peak / 20.0).toFloat()
    }

    fun reset() = z.forEach { band -> band.forEach { it.fill(0f) } }

    fun process(x: Float, ch: Int): Float {
        var y = x * preamp
        for (i in 0 until 10) {
            if (!on[i]) continue
            val k = c[i]
            val s = z[i][ch]
            val out = k[0] * y + s[0]
            s[0] = k[1] * y - k[3] * out + s[1]
            s[1] = k[2] * y - k[4] * out
            y = out
        }
        return y
    }
}

/**
 * Applies the equalizer to the PCM the player hands to the sink, in any PCM encoding
 * (16, 24, 32 bit or float), so high resolution output keeps working. Media3 skips
 * custom audio processors on its float path, which is why this sits in the sink.
 */
@UnstableApi
class EqSink(sink: AudioSink) : ForwardingAudioSink(sink) {
    private var encoding = C.ENCODING_PCM_16BIT
    private var channels = 2
    private var filter: EqFilter? = null
    private var out: ByteBuffer? = null
    private var source: ByteBuffer? = null
    private var sourceStart = 0

    override fun configure(audioSinkConfig: AudioSink.AudioSinkConfig) {
        val f = audioSinkConfig.format
        encoding = f.pcmEncoding
        channels = max(1, f.channelCount)
        filter = if (f.sampleRate > 0) EqFilter(f.sampleRate, channels) else null
        source = null
        super.configure(audioSinkConfig)
    }

    override fun flush() {
        filter?.reset()
        source = null
        super.flush()
    }

    override fun reset() {
        filter?.reset()
        source = null
        super.reset()
    }

    private fun bytes() =
        when (encoding) {
            C.ENCODING_PCM_16BIT -> 2
            C.ENCODING_PCM_24BIT -> 3
            C.ENCODING_PCM_32BIT, C.ENCODING_PCM_FLOAT -> 4
            else -> 0
        }

    override fun handleBuffer(buffer: ByteBuffer, presentationTimeUs: Long, encodedAccessUnitCount: Int): Boolean {
        val f = filter
        val size = bytes()
        f?.update()
        if (f == null || size == 0 || !f.active) {
            source = null
            return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount)
        }
        // The player offers the same buffer again until the sink takes all of it: filter it once.
        if (source == null || source !== buffer || out == null) {
            source = buffer
            sourceStart = buffer.position()
            val n = buffer.remaining()
            var o = out
            if (o == null || o.capacity() < n) o = ByteBuffer.allocateDirect(max(n, 16384)).order(ByteOrder.nativeOrder())
            o!!.clear()
            val b = buffer.duplicate().order(ByteOrder.nativeOrder())
            val frames = n / (size * channels)
            var at = b.position()
            for (fr in 0 until frames) {
                for (ch in 0 until channels) {
                    when (encoding) {
                        C.ENCODING_PCM_16BIT -> {
                            val y = f.process(b.getShort(at) / 32768f, ch)
                            o.putShort((y * 32767f).coerceIn(-32768f, 32767f).toInt().toShort())
                        }
                        C.ENCODING_PCM_24BIT -> {
                            val v = (b.get(at).toInt() and 0xff) or ((b.get(at + 1).toInt() and 0xff) shl 8) or (b.get(at + 2).toInt() shl 16)
                            val y = (f.process(v / 8388608f, ch) * 8388607f).coerceIn(-8388608f, 8388607f).toInt()
                            o.put(y.toByte()).put((y shr 8).toByte()).put((y shr 16).toByte())
                        }
                        C.ENCODING_PCM_32BIT -> {
                            val y = f.process(b.getInt(at) / 2147483648f, ch).toDouble()
                            o.putInt((y * 2147483647.0).coerceIn(-2147483648.0, 2147483647.0).toInt())
                        }
                        else -> o.putFloat(f.process(b.getFloat(at), ch))
                    }
                    at += size
                }
            }
            // A trailing partial frame (should not happen) passes unchanged.
            while (at < b.limit()) o.put(b.get(at++))
            o.flip()
            out = o
        }
        val o = out!!
        val done = super.handleBuffer(o, presentationTimeUs, encodedAccessUnitCount)
        // Mirror how much the sink took on the player's buffer.
        buffer.position(minOf(buffer.limit(), sourceStart + o.position()))
        if (done) {
            buffer.position(buffer.limit())
            source = null
        }
        return done
    }
}
