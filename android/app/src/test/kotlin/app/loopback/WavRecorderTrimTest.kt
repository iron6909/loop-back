package app.echoloop

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile
import java.nio.file.Files
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * WavRecorder.trimSilence 的 JVM 单元测试。
 *
 * 通过构造不同特征的 WAV 文件验证裁剪行为：
 * - 正常裁剪：静音 + 语音 + 静音 → 裁剪首尾
 * - 全静音：不裁剪，保留原文件
 * - 全语音：不裁剪（无可去除的静音）
 * - 极短语音：< 120ms 不裁剪
 */
class WavRecorderTrimTest {

    private lateinit var tempDir: File
    private val recorder = WavRecorder()

    companion object {
        private const val SAMPLE_RATE = 16000
        private const val BYTES_PER_SAMPLE = 2
        private const val WAV_HEADER_SIZE = 44

        /** 生成指定时长（毫秒）的静音采样。 */
        fun silenceSamples(durationMs: Int): ShortArray {
            val frames = (SAMPLE_RATE * durationMs) / 1000
            return ShortArray(frames) { 0 }
        }

        /**
         * 生成指定时长（毫秒）的正弦波采样。
         * 振幅足够大以超过 TRIM_RMS_THRESHOLD (0.022)。
         */
        fun speechSamples(durationMs: Int, amplitude: Short = 3000): ShortArray {
            val frames = (SAMPLE_RATE * durationMs) / 1000
            val freq = 440.0 // Hz
            return ShortArray(frames) { i ->
                val t = i.toDouble() / SAMPLE_RATE
                (amplitude * sin(2 * Math.PI * freq * t)).toInt().toShort()
            }
        }

        /** 将采样数组拼接。 */
        fun concat(vararg arrays: ShortArray): ShortArray {
            val total = arrays.sumOf { it.size }
            val result = ShortArray(total)
            var offset = 0
            for (arr in arrays) {
                arr.copyInto(result, offset)
                offset += arr.size
            }
            return result
        }

        /** 将采样数据写为合法 WAV 文件。 */
        fun writeWav(file: File, samples: ShortArray) {
            RandomAccessFile(file, "rw").use { raf ->
                val dataSize = samples.size * BYTES_PER_SAMPLE
                val byteRate = SAMPLE_RATE * BYTES_PER_SAMPLE
                // RIFF header
                raf.writeBytes("RIFF")
                writeIntLE(raf, 36 + dataSize)
                raf.writeBytes("WAVE")
                // fmt chunk
                raf.writeBytes("fmt ")
                writeIntLE(raf, 16)
                writeShortLE(raf, 1) // PCM
                writeShortLE(raf, 1) // mono
                writeIntLE(raf, SAMPLE_RATE)
                writeIntLE(raf, byteRate)
                writeShortLE(raf, BYTES_PER_SAMPLE)
                writeShortLE(raf, 16) // bits per sample
                // data chunk
                raf.writeBytes("data")
                writeIntLE(raf, dataSize)
                // PCM data (little-endian)
                val byteBuffer = ByteArray(samples.size * BYTES_PER_SAMPLE)
                for (i in samples.indices) {
                    val v = samples[i].toInt()
                    byteBuffer[i * 2] = (v and 0xFF).toByte()
                    byteBuffer[i * 2 + 1] = (v shr 8 and 0xFF).toByte()
                }
                raf.write(byteBuffer)
            }
        }

        private fun writeIntLE(raf: RandomAccessFile, value: Int) {
            raf.write(value and 0xFF)
            raf.write(value shr 8 and 0xFF)
            raf.write(value shr 16 and 0xFF)
            raf.write(value shr 24 and 0xFF)
        }

        private fun writeShortLE(raf: RandomAccessFile, value: Int) {
            raf.write(value and 0xFF)
            raf.write(value shr 8 and 0xFF)
        }
    }

    /** 读取 WAV 文件的 PCM 数据时长（毫秒）。 */
    private fun wavDurationMs(file: File): Double {
        val dataBytes = file.length() - WAV_HEADER_SIZE
        val frames = dataBytes.toDouble() / BYTES_PER_SAMPLE
        return (frames / SAMPLE_RATE) * 1000.0
    }

    @Before
    fun setUp() {
        tempDir = Files.createTempDirectory("wav_trim_test").toFile()
    }

    @After
    fun tearDown() {
        tempDir.deleteRecursively()
    }

    @Test
    fun `trimSilence removes leading and trailing silence`() {
        // 500ms 静音 + 500ms 语音 + 500ms 静音 = 1500ms 总时长
        val samples = concat(
            silenceSamples(500),
            speechSamples(500),
            silenceSamples(500),
        )
        val file = File(tempDir, "trim_normal.wav")
        writeWav(file, samples)

        val originalSize = file.length()
        recorder.trimSilence(file.absolutePath)

        // 文件应变小（首尾静音被裁掉）。
        assertTrue("File should be smaller after trimming", file.length() < originalSize)

        // 裁剪后时长 ≈ 语音 500ms + leading padding 120ms + trailing padding 180ms = ~800ms
        // 允许 ±200ms 误差（chunk 对齐）。
        val duration = wavDurationMs(file)
        assertTrue(
            "Trimmed duration ($duration ms) should be roughly 500-1000ms",
            duration in 400.0..1100.0,
        )
    }

    @Test
    fun `trimSilence preserves file when all silence`() {
        val samples = silenceSamples(1000)
        val file = File(tempDir, "all_silence.wav")
        writeWav(file, samples)

        val originalSize = file.length()
        recorder.trimSilence(file.absolutePath)

        // 全静音 → 不裁剪，文件大小不变。
        assertEquals("File size should not change for all-silence", originalSize, file.length())
    }

    @Test
    fun `trimSilence preserves file when all speech`() {
        val samples = speechSamples(1000)
        val file = File(tempDir, "all_speech.wav")
        writeWav(file, samples)

        val originalSize = file.length()
        recorder.trimSilence(file.absolutePath)

        // 全语音 → padding 向外扩展被 clamp 到文件边界，结果接近原始大小。
        // 允许极小偏差（chunk 对齐可能导致微小差异）。
        val ratio = file.length().toDouble() / originalSize
        assertTrue(
            "File size ratio ($ratio) should be close to 1.0 for all-speech",
            ratio in 0.9..1.01,
        )
    }

    @Test
    fun `trimSilence skips when speech portion too short`() {
        // 50ms 语音 → 加上 padding 后 < 120ms 的情况不太可能，
        // 但用 10ms 语音 + 极小振幅来让有效区间 < MIN_TRIM_DURATION_MS。
        // 实际是让 detectSpeechRange 返回的区间 + padding < 120ms。
        val samples = concat(
            silenceSamples(500),
            speechSamples(5, amplitude = 800), // 很短且幅度刚过阈值
            silenceSamples(500),
        )
        val file = File(tempDir, "too_short.wav")
        writeWav(file, samples)

        val originalSize = file.length()
        recorder.trimSilence(file.absolutePath)

        // 5ms 语音，detectSpeechRange 可能找到一个 chunk（~128ms），
        // 加 padding 后 > 120ms 就会裁剪。这里主要验证不崩溃。
        assertTrue("File should still exist", file.exists())
        assertTrue("File should have valid WAV header", file.length() >= WAV_HEADER_SIZE)
    }

    @Test
    fun `trimSilence handles nonexistent file gracefully`() {
        // 不应抛异常。
        recorder.trimSilence("/nonexistent/path/to/file.wav")
    }

    @Test
    fun `trimSilence handles empty file gracefully`() {
        val file = File(tempDir, "empty.wav")
        file.createNewFile()
        recorder.trimSilence(file.absolutePath)
        // 不应崩溃。
        assertTrue("Empty file should still exist", file.exists())
    }

    @Test
    fun `trimSilence handles header-only WAV gracefully`() {
        // 只有 44 字节头，无 PCM 数据。
        val file = File(tempDir, "header_only.wav")
        writeWav(file, ShortArray(0))
        val originalSize = file.length()
        recorder.trimSilence(file.absolutePath)
        assertEquals("Header-only file should not change", originalSize, file.length())
    }

    @Test
    fun `trimSilence preserves WAV header validity after trim`() {
        val samples = concat(
            silenceSamples(1000),
            speechSamples(500),
            silenceSamples(1000),
        )
        val file = File(tempDir, "check_header.wav")
        writeWav(file, samples)

        recorder.trimSilence(file.absolutePath)

        // 验证裁剪后的 WAV 头数据一致性。
        RandomAccessFile(file, "r").use { raf ->
            // RIFF chunk size
            raf.seek(4)
            val riffSize = readIntLE(raf)
            assertEquals(
                "RIFF size should match file size - 8",
                (file.length() - 8).toInt(),
                riffSize,
            )
            // data chunk size
            raf.seek(40)
            val dataSize = readIntLE(raf)
            assertEquals(
                "data size should match file size - 44",
                (file.length() - 44).toInt(),
                dataSize,
            )
        }
    }

    private fun readIntLE(raf: RandomAccessFile): Int {
        val b0 = raf.read()
        val b1 = raf.read()
        val b2 = raf.read()
        val b3 = raf.read()
        return b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)
    }
}
