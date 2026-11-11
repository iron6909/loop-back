package app.echoloop

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

/**
 * Android 原生音频解码桥接，为 Flutter 字幕自动校准提供低采样率 PCM 数据。
 *
 * 协议与 iOS (`IOSAudioDecodeHandler`) / macOS (`MacAudioDecodeHandler`) 完全一致：
 * - MethodChannel：`top.echo-loop/audio_decode`
 * - 方法：`decode`，参数 `{audioPath: String}`
 * - 返回：`{sampleRate: Int, pcmBytes: ByteArray}`（单声道 Float32 LE，目标 1000 Hz）
 * - 失败错误码：`invalidArguments` / `fileNotFound` / `notAvailable` / `decodeFailed`
 *
 * 解码使用 `MediaExtractor` + `MediaCodec`，与 Apple 侧同样采用最近邻重采样并
 * 在多声道时取算术平均。重采样与混音逻辑被抽取到纯函数 [PcmDownsampler]，
 * 便于在 JVM 单测中直接覆盖。
 */
class AndroidAudioDecodeHandler(binaryMessenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val methodChannel = MethodChannel(binaryMessenger, CHANNEL_NAME)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "AudioDecodeWorker").apply { isDaemon = true }
    }

    init {
        methodChannel.setMethodCallHandler(this)
    }

    /** 释放资源，MainActivity.cleanUpFlutterEngine 时调用。 */
    fun dispose() {
        methodChannel.setMethodCallHandler(null)
        executor.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "decode" -> {
                val audioPath = call.argument<String>("audioPath")
                if (audioPath.isNullOrEmpty()) {
                    result.error(
                        "invalidArguments",
                        "Missing 'audioPath' parameter",
                        null,
                    )
                    return
                }
                executor.execute {
                    try {
                        val payload = decodeAudio(audioPath)
                        mainHandler.post { result.success(payload) }
                    } catch (error: AudioDecodeException) {
                        mainHandler.post {
                            result.error(error.code, error.message, error.details)
                        }
                    } catch (error: Throwable) {
                        mainHandler.post {
                            result.error(
                                "decodeFailed",
                                error.message ?: error.javaClass.simpleName,
                                null,
                            )
                        }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun decodeAudio(audioPath: String): Map<String, Any> {
        val file = File(audioPath)
        if (!file.exists()) {
            throw AudioDecodeException(
                code = "fileNotFound",
                message = "Audio file does not exist",
                details = audioPath,
            )
        }

        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(file.absolutePath)

            var trackIndex = -1
            var inputFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val fmt = extractor.getTrackFormat(i)
                val mime = fmt.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    trackIndex = i
                    inputFormat = fmt
                    break
                }
            }
            if (trackIndex < 0 || inputFormat == null) {
                throw AudioDecodeException(
                    code = "notAvailable",
                    message = "Audio asset has no readable audio track",
                )
            }
            extractor.selectTrack(trackIndex)

            val mime = inputFormat.getString(MediaFormat.KEY_MIME)!!
            val initialSampleRate = requirePositive(
                inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE),
                "sample rate",
            ).toDouble()
            val initialChannels = requirePositive(
                inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT),
                "channel count",
            )

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(inputFormat, null, null, 0)
            codec.start()

            val downsampler = PcmDownsampler(
                inputSampleRate = initialSampleRate,
                targetSampleRate = TARGET_SAMPLE_RATE,
                channelCount = initialChannels,
            )

            val bufferInfo = MediaCodec.BufferInfo()
            var sawInputEos = false
            var sawOutputEos = false

            while (!sawOutputEos) {
                if (!sawInputEos) {
                    val inIdx = codec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                    if (inIdx >= 0) {
                        val inBuf = codec.getInputBuffer(inIdx)
                            ?: throw AudioDecodeException(
                                code = "decodeFailed",
                                message = "Decoder returned null input buffer",
                            )
                        val sampleSize = extractor.readSampleData(inBuf, 0)
                        if (sampleSize < 0) {
                            codec.queueInputBuffer(
                                inIdx, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            sawInputEos = true
                        } else {
                            val presentationTimeUs = extractor.sampleTime
                            codec.queueInputBuffer(
                                inIdx, 0, sampleSize, presentationTimeUs, 0,
                            )
                            extractor.advance()
                        }
                    }
                }

                val outIdx = codec.dequeueOutputBuffer(bufferInfo, DEQUEUE_TIMEOUT_US)
                when {
                    outIdx >= 0 -> {
                        if (bufferInfo.size > 0) {
                            val outBuf = codec.getOutputBuffer(outIdx)
                                ?: throw AudioDecodeException(
                                    code = "decodeFailed",
                                    message = "Decoder returned null output buffer",
                                )
                            outBuf.position(bufferInfo.offset)
                            outBuf.limit(bufferInfo.offset + bufferInfo.size)
                            val chunk = ByteArray(bufferInfo.size)
                            outBuf.get(chunk)
                            downsampler.appendPcm16LeChunk(chunk)
                        }
                        codec.releaseOutputBuffer(outIdx, false)
                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            sawOutputEos = true
                        }
                    }
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val newFormat = codec.outputFormat
                        val newRate = if (newFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                            newFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE).toDouble()
                        } else {
                            downsampler.inputSampleRate
                        }
                        val newChannels =
                            if (newFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                                newFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            } else {
                                downsampler.channelCount
                            }
                        downsampler.reconfigureIfNeeded(newRate, newChannels)
                    }
                    // INFO_TRY_AGAIN_LATER / INFO_OUTPUT_BUFFERS_CHANGED 等忽略，继续循环。
                    else -> Unit
                }
            }

            val floatSamples = downsampler.takeOutput()
            val pcmBytes = encodeFloatLe(floatSamples)
            return mapOf(
                "sampleRate" to TARGET_SAMPLE_RATE.toInt(),
                "pcmBytes" to pcmBytes,
            )
        } finally {
            try {
                codec?.stop()
            } catch (_: IllegalStateException) {
                // 已 stop / 未 start，忽略。
            }
            codec?.release()
            extractor.release()
        }
    }

    private fun requirePositive(value: Int, name: String): Int {
        if (value <= 0) {
            throw AudioDecodeException(
                code = "notAvailable",
                message = "Audio has invalid $name ($value)",
            )
        }
        return value
    }

    companion object {
        const val CHANNEL_NAME = "top.echo-loop/audio_decode"
        // 与 iOS / macOS 对齐：最终输出 1000 Hz 单声道，供字幕自动校准使用。
        private const val TARGET_SAMPLE_RATE = 1000.0
        private const val DEQUEUE_TIMEOUT_US = 10_000L

        /** 把内部 Float32 样本序列转成 little-endian 字节数组。 */
        internal fun encodeFloatLe(samples: FloatArray): ByteArray {
            val buffer = ByteBuffer.allocate(samples.size * 4).order(ByteOrder.LITTLE_ENDIAN)
            for (sample in samples) {
                buffer.putFloat(sample)
            }
            return buffer.array()
        }
    }
}

/**
 * 平台侧解码错误，映射为 `FlutterError(code, message, details)`。
 */
class AudioDecodeException(
    val code: String,
    override val message: String,
    val details: Any? = null,
) : RuntimeException(message)

/**
 * 流式最近邻重采样 + 多声道混合。
 *
 * 行为严格对齐 Apple 侧 `decodeAudio` 中的内联算法：
 * - `resampleRatio = inputSampleRate / targetSampleRate`
 * - 累加器 `nextOutputSourceFrame` 在源采样空间上步进
 * - 每个输出样本取当前 chunk 内 `nextOutputSourceFrame` 对应的源帧（钳制到 chunk 尾），
 *   多声道取算术平均
 * - chunk 之间只保留累加器，不缓存跨 chunk 的旧样本
 */
internal class PcmDownsampler(
    inputSampleRate: Double,
    private val targetSampleRate: Double,
    channelCount: Int,
) {
    var inputSampleRate: Double = inputSampleRate
        private set
    var channelCount: Int = channelCount
        private set

    private var resampleRatio = inputSampleRate / targetSampleRate
    private var nextOutputSourceFrame = 0.0
    private var processedSourceFrames = 0.0
    private val output = ArrayList<Float>()

    /** 追加一段 16-bit little-endian 交错多声道 PCM 字节，内部会做混合与重采样。 */
    fun appendPcm16LeChunk(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        val shortBuffer = ByteBuffer.wrap(bytes)
            .order(ByteOrder.LITTLE_ENDIAN)
            .asShortBuffer()
        val totalShorts = shortBuffer.remaining()
        val frameLength = totalShorts / channelCount
        if (frameLength <= 0) return

        val chunkStartFrame = processedSourceFrames
        val chunkEndFrame = chunkStartFrame + frameLength.toDouble()

        while (nextOutputSourceFrame < chunkEndFrame) {
            val localFrame = min(
                max(0, (nextOutputSourceFrame - chunkStartFrame).toInt()),
                frameLength - 1,
            )
            val frameOffset = localFrame * channelCount
            var mixed = 0f
            for (channel in 0 until channelCount) {
                mixed += shortBuffer.get(frameOffset + channel) / 32768f
            }
            output.add(mixed / channelCount)
            nextOutputSourceFrame += resampleRatio
        }

        processedSourceFrames = chunkEndFrame
    }

    /** MediaCodec 输出格式变化时同步更新采样率与声道数；重置仅在采样率变化时进行。 */
    fun reconfigureIfNeeded(newInputSampleRate: Double, newChannelCount: Int) {
        if (newChannelCount > 0 && newChannelCount != channelCount) {
            channelCount = newChannelCount
        }
        if (newInputSampleRate > 0 && newInputSampleRate != inputSampleRate) {
            inputSampleRate = newInputSampleRate
            resampleRatio = newInputSampleRate / targetSampleRate
        }
    }

    /** 取出已经累积的单声道 Float32 样本。调用后内部 output 清空。 */
    fun takeOutput(): FloatArray {
        val result = FloatArray(output.size)
        for (i in output.indices) {
            result[i] = output[i]
        }
        output.clear()
        return result
    }
}
