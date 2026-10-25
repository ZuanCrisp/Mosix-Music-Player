package xyz.luan.audioplayers.player

import android.media.audiofx.DynamicsProcessing
import androidx.annotation.RequiresApi
import kotlin.math.log10
import kotlin.math.sqrt

/** Per-player effect: never attaches to session zero or other apps' audio. */
@RequiresApi(28)
internal class PlaybackEqualizer(private val session: Int) {
    private var effect: DynamicsProcessing? = null
    private var bandCount = 0

    fun configure(data: Map<String, Any?>) {
        if (data["enabled"] != true) { close(); return }
        check(session > 0) { "No active audio session for equalizer" }
        val gains = (data["gains"] as? List<*>)?.map { (it as Number).toFloat() }
            ?: error("Missing equalizer bands")
        val frequencies = (data["frequencies"] as? List<*>)?.map { (it as Number).toFloat() }
            ?: error("Missing equalizer frequencies")
        require(gains.size in listOf(5, 10, 15, 31) && gains.size == frequencies.size)
        require(gains.all { it.isFinite() && it in -24f..24f })
        require(frequencies.all { it.isFinite() && it > 0f })
        require(frequencies.zipWithNext().all { (left, right) -> left < right })
        fun number(key: String, fallback: Float, min: Float, max: Float): Float =
            ((data[key] as? Number)?.toFloat() ?: fallback).let {
                require(it.isFinite())
                it.coerceIn(min, max)
            }
        if (effect == null || bandCount != gains.size) {
            close()
            val config = DynamicsProcessing.Config.Builder(
                DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION, 2,
                true, gains.size, true, 1, false, 0, true,
            ).build()
            effect = DynamicsProcessing(0, session, config)
            bandCount = gains.size
        }
        val dsp = requireNotNull(effect)
        val input = number("inputGain", 0f, -48f, 12f)
        val balance = number("balance", 0f, -1f, 1f)
        for (channel in 0 until dsp.channelCount) {
            val amplitude = when (channel) {
                0 -> if (balance > 0) 1f - balance else 1f
                1 -> if (balance < 0) 1f + balance else 1f
                else -> 1f
            }
            dsp.setInputGainbyChannel(channel, input + 20f * log10(amplitude.coerceAtLeast(0.000001f)))
        }
        for (index in gains.indices) {
            val cutoff = if (index == gains.lastIndex) 24000f
                else sqrt(frequencies[index] * frequencies[index + 1])
            dsp.setPreEqBandAllChannelsTo(index, DynamicsProcessing.EqBand(true, cutoff, gains[index]))
        }
        val compressor = dsp.getMbcBandByChannelIndex(0, 0).apply {
            isEnabled = data["compressor"] == true
            cutoffFrequency = 24000f
            attackTime = number("attack", 10f, 1f, 100f)
            releaseTime = number("release", 150f, 20f, 1000f)
            threshold = number("threshold", -18f, -60f, 0f)
            ratio = number("ratio", 3f, 1f, 20f)
            kneeWidth = 6f
            noiseGateThreshold = -120f
            expanderRatio = 1f
            preGain = 0f
            postGain = 0f
        }
        dsp.setMbcBandAllChannelsTo(0, compressor)
        dsp.setLimiterAllChannelsTo(DynamicsProcessing.Limiter(
            true, data["limiter"] != false, 0, 1f, 60f, 20f, -0.5f, 0f,
        ))
        check(dsp.setEnabled(true) == 0) { "Device rejected the equalizer" }
    }

    fun close() {
        effect?.release()
        effect = null
        bandCount = 0
    }
}
