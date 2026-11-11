package app.echoloop

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * `PcmDownsampler` 的 JVM 单测。
 *
 * 只覆盖纯算法部分，不涉及 MediaExtractor / MediaCodec；
 * 验证目标：行为与 iOS `IOSAudioDecodeHandler.decodeAudio` 中的最近邻
 * 重采样 + 多声道算术平均一致，并在 chunk 跨批、采样率变化等边界下稳定。
 */
class PcmDownsamplerTest {

    private fun encodePcm16LeMono(samples: ShortArray): ByteArray {
        val bytes = ByteArray(samples.size * 2)
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        for (s in samples) buf.putShort(s)
        return bytes
    }

    /** 构造 [frames] 帧、`channelCount` 声道的交错 PCM16 LE 字节流。 */
    private fun encodePcm16LeInterleaved(
        channelCount: Int,
        buildSample: (frame: Int, channel: Int) -> Short,
        frames: Int,
    ): ByteArray {
        val bytes = ByteArray(frames * channelCount * 2)
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        for (frame in 0 until frames) {
            for (channel in 0 until channelCount) {
                buf.putShort(buildSample(frame, channel))
            }
        }
        return bytes
    }

    @Test
    fun singleChunk_monoDownsample_pickNearestNeighborEveryRatio() {
        // 8000 Hz -> 1000 Hz，比例 8；预期从 8000 帧取 1000 帧。
        val inputRate = 8000.0
        val frames = 8000
        val input = ShortArray(frames) { it.toShort() }

        val downsampler = PcmDownsampler(
            inputSampleRate = inputRate,
            targetSampleRate = 1000.0,
            channelCount = 1,
        )
        downsampler.appendPcm16LeChunk(encodePcm16LeMono(input))
        val output = downsampler.takeOutput()

        assertEquals(1000, output.size)
        // 最近邻：输出第 k 个值的源帧下标应该是 round(k * 8) - 但这里是 floor(k*8 - 0)
        // 对齐 iOS 公式 nextOutputSourceFrame += 8，localFrame = floor(nextOutputSourceFrame)。
        for (k in 0 until 1000) {
            val sourceFrame = k * 8
            val expected = sourceFrame.toShort() / 32768f
            assertEquals("mismatch at k=$k", expected, output[k], 1e-6f)
        }
    }

    @Test
    fun chunkedInput_sameResultAsSingleChunk() {
        // 将同一段 PCM 分成多个 chunk 喂入，结果应和一次性喂入完全一致。
        val inputRate = 44100.0
        val totalFrames = 44100 // 1 秒
        val fullInput = ShortArray(totalFrames) { ((it % 200) - 100).toShort() }

        val oneShot = PcmDownsampler(inputRate, 1000.0, 1)
        oneShot.appendPcm16LeChunk(encodePcm16LeMono(fullInput))
        val expected = oneShot.takeOutput()

        val streamed = PcmDownsampler(inputRate, 1000.0, 1)
        val chunkSize = 1023 // 故意取一个不能整除的尺寸
        var offset = 0
        while (offset < totalFrames) {
            val end = minOf(offset + chunkSize, totalFrames)
            val chunk = ShortArray(end - offset) { fullInput[offset + it] }
            streamed.appendPcm16LeChunk(encodePcm16LeMono(chunk))
            offset = end
        }
        val actual = streamed.takeOutput()

        assertEquals(expected.size, actual.size)
        assertArrayEquals(expected, actual, 1e-6f)
    }

    @Test
    fun stereo_averagesTwoChannels() {
        // 双声道：左声道恒为 +10000，右声道恒为 -10000，混合后应接近 0。
        val inputRate = 2000.0
        val frames = 2000
        val bytes = encodePcm16LeInterleaved(
            channelCount = 2,
            buildSample = { _, channel -> if (channel == 0) 10000 else -10000 },
            frames = frames,
        )
        val downsampler = PcmDownsampler(inputRate, 1000.0, 2)
        downsampler.appendPcm16LeChunk(bytes)
        val output = downsampler.takeOutput()

        assertEquals(1000, output.size)
        for (sample in output) {
            assertEquals(0f, sample, 1e-6f)
        }
    }

    @Test
    fun stereo_fourChannelAverage_matchesArithmeticMean() {
        // 四声道，每帧四个通道不同取值；期望输出 = 算术平均后再归一化。
        val frames = 2000
        val inputRate = 2000.0
        val values = intArrayOf(4000, 8000, -4000, -8000) // 平均 0
        val bytes = encodePcm16LeInterleaved(
            channelCount = 4,
            buildSample = { _, channel -> values[channel].toShort() },
            frames = frames,
        )
        val downsampler = PcmDownsampler(inputRate, 1000.0, 4)
        downsampler.appendPcm16LeChunk(bytes)
        val output = downsampler.takeOutput()

        assertEquals(1000, output.size)
        for (sample in output) {
            assertEquals(0f, sample, 1e-6f)
        }
    }

    @Test
    fun sineWave_preservesLowFrequencyShape() {
        // 输入 50 Hz 正弦波（远低于 500 Hz Nyquist），输出应基本保留波形。
        val inputRate = 16000.0
        val targetRate = 1000.0
        val frames = inputRate.toInt() // 1 秒
        val freq = 50.0
        val input = ShortArray(frames) { i ->
            val t = i / inputRate
            (sin(2 * PI * freq * t) * 20000).roundToInt().toShort()
        }
        val downsampler = PcmDownsampler(inputRate, targetRate, 1)
        downsampler.appendPcm16LeChunk(encodePcm16LeMono(input))
        val output = downsampler.takeOutput()

        assertEquals(1000, output.size)
        // 检查峰值幅度在 [0.5, 0.7] 内（20000/32768 ≈ 0.61），至少一个周期能找到近峰值。
        var maxAbs = 0f
        for (s in output) if (kotlin.math.abs(s) > maxAbs) maxAbs = kotlin.math.abs(s)
        assertTrue("peak too low: $maxAbs", maxAbs > 0.5f)
        assertTrue("peak too high: $maxAbs", maxAbs < 0.7f)
    }

    @Test
    fun reconfigure_updatesSampleRateMidStream() {
        // 前半段 8000 Hz，后半段报告 16000 Hz，重配置后步进变大。
        val ds = PcmDownsampler(8000.0, 1000.0, 1)
        ds.appendPcm16LeChunk(encodePcm16LeMono(ShortArray(8000) { 1000 }))
        val phase1 = ds.takeOutput()
        assertEquals(1000, phase1.size)

        ds.reconfigureIfNeeded(16000.0, 1)
        assertEquals(16000.0, ds.inputSampleRate, 0.0)

        // 再给 16000 帧，对应 1000 Hz 下还是 1000 个样本。
        ds.appendPcm16LeChunk(encodePcm16LeMono(ShortArray(16000) { 2000 }))
        val phase2 = ds.takeOutput()
        assertEquals(1000, phase2.size)
        for (sample in phase2) {
            assertEquals(2000f / 32768f, sample, 1e-4f)
        }
    }

    @Test
    fun encodeFloatLe_writesLittleEndianFloat32() {
        // 验证与 iOS 侧返回约定一致：Float32 LE。
        val samples = floatArrayOf(0f, 1f, -1f, 0.5f)
        val bytes = AndroidAudioDecodeHandler.encodeFloatLe(samples)
        assertEquals(16, bytes.size)
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(0f, buf.float, 0f)
        assertEquals(1f, buf.float, 0f)
        assertEquals(-1f, buf.float, 0f)
        assertEquals(0.5f, buf.float, 0f)
    }

    @Test
    fun emptyChunk_producesNoOutput() {
        val ds = PcmDownsampler(8000.0, 1000.0, 1)
        ds.appendPcm16LeChunk(ByteArray(0))
        assertEquals(0, ds.takeOutput().size)
    }
}
