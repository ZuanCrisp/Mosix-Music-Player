package com.zuancrisp.mosix

import android.media.AudioFormat
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.Closeable
import java.io.FileInputStream
import java.nio.ByteBuffer

/** A source for the direct driver; decoding never passes through AudioTrack. */
internal class UsbPcmSource(path: String) : Closeable {
    private var extractor: MediaExtractor? = null
    private var flac = 0L
    private val raw = ByteBuffer.allocateDirect(256 * 1024)
    private var converted: ByteBuffer? = null
    var ended = false
        private set
    private var inputBits = 0
    private var targetUs = 0L
    private var flacFrame = 0L
    var bufferTimeUs = 0L
        private set
    val rate: Int
    val channels: Int
    val bits: Int
    val durationUs: Long

    init {
        try {
            val header = ByteArray(42)
            FileInputStream(path).use { input ->
                var n = 0
                while (n < header.size) {
                    val count = input.read(header, n, header.size - n)
                    if (count <= 0) break
                    n += count
                }
            }
            if (BitPerfectPcm.flacFormat(header) != null) {
                // Some vendor extractors report FLAC as audio/raw and silently
                // truncate it to 16-bit. Open the original file with libFLAC.
                flac = NativeAudio.openFlac(path)
                val format = NativeAudio.infoFlac(flac)
                rate = format[0].toInt()
                channels = format[1].toInt()
                bits = format[2].toInt()
                durationUs = format[3] * 1000000 / rate
            } else {
                val media = MediaExtractor().also { extractor = it }
                FileInputStream(path).use { media.setDataSource(it.fd) }
                val index = (0 until media.trackCount).firstOrNull {
                    media.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
                } ?: error("No audio stream")
                media.selectTrack(index)
                val format = media.getTrackFormat(index)
                require(format.getString(MediaFormat.KEY_MIME) == "audio/raw") {
                    "Direct USB supports integer FLAC/WAV and DSF/DFF"
                }
                rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0
                bits = precision(format.getInteger(MediaFormat.KEY_PCM_ENCODING))
                inputBits = bits
            }
            require(channels in 1..2 && bits in listOf(16, 24, 32))
        } catch (error: Exception) { close(); throw error }
    }

    private fun precision(encoding: Int) = when (encoding) {
        AudioFormat.ENCODING_PCM_16BIT -> 16
        AudioFormat.ENCODING_PCM_24BIT_PACKED -> 24
        AudioFormat.ENCODING_PCM_32BIT -> 32
        else -> 0
    }

    private fun convert(buffer: ByteBuffer, timeUs: Long, outputBits: Int): ByteBuffer {
        val frame = channels * (inputBits / 8)
        require(frame > 0 && buffer.remaining() % frame == 0)
        val skip = if (timeUs < targetUs) ((targetUs - timeUs) * rate + 999999) / 1000000 else 0
        buffer.position(buffer.position() + minOf(skip, (buffer.remaining() / frame).toLong()).toInt() * frame)
        bufferTimeUs = maxOf(timeUs, targetUs)
        // The playback worker consumes this result before requesting another buffer.
        return BitPerfectPcm.convert(buffer, inputBits, bits, outputBits, false, converted)
            .also { converted = it }
    }

    fun read(outputBits: Int): ByteBuffer? {
        if (ended) return null
        if (flac != 0L) {
            raw.clear()
            val size = NativeAudio.readFlac(flac, raw, outputBits)
            if (size == 0) { ended = true; return null }
            raw.limit(size)
            bufferTimeUs = flacFrame * 1000000 / rate
            flacFrame += size / (channels * (outputBits / 8))
            return raw
        }
        val media = requireNotNull(extractor)
        raw.clear()
        val size = media.readSampleData(raw, 0)
        if (size < 0) { ended = true; return null }
        raw.limit(size)
        raw.position(0)
        val output = convert(raw, media.sampleTime, outputBits)
        media.advance()
        return output
    }

    fun seek(positionUs: Long) {
        targetUs = positionUs.coerceAtLeast(0)
        if (flac != 0L) {
            flacFrame = targetUs / 1000000 * rate + (targetUs % 1000000 * rate + 999999) / 1000000
            NativeAudio.seekFlac(flac, flacFrame)
        } else extractor?.seekTo(targetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        ended = false
    }

    override fun close() {
        if (flac != 0L) runCatching { NativeAudio.closeFlac(flac) }
        flac = 0
        converted = null
        runCatching { extractor?.release() }
        extractor = null
    }
}
