package pl.mytify.mytify

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer
import java.security.MessageDigest

class AirplaySession(context: Context, val target: NetworkTarget) : AutoCloseable {
    private val prefs = context.getSharedPreferences("airplay-private", 0)
    private val key =
        MessageDigest.getInstance("SHA-256").digest(target.id.toByteArray()).joinToString("") {
            "%02x".format(it)
        }
    private var signalGain = context.getSharedPreferences("player", 0).getFloat("volume", 0.8f)
    private var pointer: Long

    init {
        val identity =
            prefs.getString("identity", null)
                ?: ByteArray(6)
                    .also {
                        java.security.SecureRandom().nextBytes(it)
                        it[0] = ((it[0].toInt() or 2) and 254).toByte()
                    }
                    .joinToString(":") { "%02X".format(it) }
                    .also { prefs.edit().putString("identity", it).apply() }
        pointer =
            nativeOpen(
                target.host,
                target.port,
                target.name,
                target.auth,
                target.ap2,
                target.id.removePrefix("airplay:"),
                prefs.getString(key, "") ?: "",
                "",
                identity,
            )
        check(pointer != 0L) { "Nie można uruchomić AirPlay" }
    }

    @Synchronized fun state(): Int = if (pointer == 0L) 4 else nativeState(pointer)

    @Synchronized
    fun text(): String = if (pointer == 0L) "Połączenie zamknięte" else nativeText(pointer, 0)

    @Synchronized
    fun persist() {
        if (pointer == 0L) return
        val c = nativeText(pointer, 1)
        if (c.isNotBlank() && c != prefs.getString(key, "")) prefs.edit().putString(key, c).apply()
    }

    @Synchronized
    fun pin(value: String) {
        require(value.matches(Regex("[0-9]{4}")))
        if (pointer != 0L) nativeCommand(pointer, 1, value)
    }

    @Synchronized
    fun flush() {
        if (pointer != 0L && nativeState(pointer) == 1) nativeCommand(pointer, 3, "")
    }

    @Synchronized
    fun volume(value: Float) {
        signalGain = value.coerceIn(0f, 1f)
    }

    @Synchronized
    fun write(buffer: ByteBuffer, rate: Int, channels: Int): Int =
        if (pointer == 0L) 0
        else
            nativeWrite(
                pointer,
                buffer,
                buffer.position(),
                buffer.remaining(),
                rate,
                channels,
                signalGain,
            )

    @Synchronized fun drain(): Int = if (pointer == 0L) 0 else nativeDrain(pointer)

    @Synchronized
    fun resetResampler() {
        if (pointer != 0L) nativeReset(pointer)
    }

    @Synchronized
    override fun close() {
        if (pointer != 0L) {
            val p = pointer
            pointer = 0
            nativeClose(p)
        }
    }

    private external fun nativeOpen(
        host: String,
        port: Int,
        name: String,
        auth: Int,
        ap2: Boolean,
        id: String,
        credentials: String,
        password: String,
        identity: String,
    ): Long

    private external fun nativeState(handle: Long): Int

    private external fun nativeCommand(handle: Long, kind: Int, text: String)

    private external fun nativeText(handle: Long, kind: Int): String

    private external fun nativeWrite(
        handle: Long,
        buffer: ByteBuffer,
        offset: Int,
        size: Int,
        rate: Int,
        channels: Int,
        gain: Float,
    ): Int

    private external fun nativeDrain(handle: Long): Int

    private external fun nativeReset(handle: Long)

    private external fun nativeClose(handle: Long)

    companion object {
        init {
            System.loadLibrary("mytify_airplay")
        }
    }
}

@UnstableApi
class AirplayProcessor(private val session: AirplaySession) : BaseAudioProcessor() {
    private var endQueued = false
    private var drained = false

    override fun onConfigure(format: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (format.encoding != C.ENCODING_PCM_16BIT || format.channelCount !in 1..2)
            throw AudioProcessor.UnhandledAudioFormatException(format)
        return format
    }

    override fun queueInput(input: ByteBuffer) {
        if (session.state() == 3 || session.state() == 4) error("AirPlay: ${session.text()}")
        val used = session.write(input, inputAudioFormat.sampleRate, inputAudioFormat.channelCount)
        if (used == 0) return
        // AudioTrack supplies the local playback clock. Only silence reaches this output.
        input.position(input.position() + used)
        val output = replaceOutputBuffer(used)
        repeat(used / 8) { output.putLong(0) }
        repeat(used % 8) { output.put(0) }
        output.flip()
    }

    override fun onQueueEndOfStream() {
        endQueued = true
    }

    override fun getOutput(): ByteBuffer {
        val pending = super.getOutput()
        if (pending.hasRemaining() || !endQueued || drained) return pending
        if (session.state() == 3 || session.state() == 4) error("AirPlay: ${session.text()}")
        val frames = session.drain()
        if (frames == 0) {
            drained = true
            return pending
        }
        if (frames < 0) return pending
        val bytes =
            maxOf(1, (frames.toLong() * inputAudioFormat.sampleRate / 44100).toInt()) *
                inputAudioFormat.channelCount *
                2
        val output = replaceOutputBuffer(bytes)
        repeat(bytes) { output.put(0) }
        output.flip()
        return super.getOutput()
    }

    override fun isEnded(): Boolean = super.isEnded() && (!endQueued || drained)

    override fun onFlush() {
        endQueued = false
        drained = false
        session.resetResampler()
        session.flush()
    }
}
