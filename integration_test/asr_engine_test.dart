/// ASR 引擎端到端集成测试。
///
/// 使用已下载的 Whisper Tiny.en int8 模型对测试 WAV 文件做转录，
/// 验证 sherpa-onnx 引擎的完整流程：初始化 → 转录 → 结果校验。
///
/// 运行方式：flutter test integration_test/asr_engine_test.dart -d macos
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:loop_back/services/asr/audio_file_reader.dart';
import 'package:loop_back/services/asr/asr_model_catalog.dart';
import 'package:loop_back/services/asr/offline_asr_engine.dart';
import 'package:loop_back/services/asr/sherpa_onnx_engine.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 测试 WAV 固件路径（运行时从网络下载到 sandbox tmp）。
late String _testWav;

/// 16kHz 测试 WAV（VAD 测试用）。
late String _testWav16k;

const _whisperTinyModel = AsrModelInfo(
  id: 'whisper-tiny-en-int8',
  displayName: 'Whisper Tiny.en',
  type: AsrModelType.whisper,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String modelDir;
  late bool modelExists;

  setUpAll(() async {
    final appDir = await getApplicationSupportDirectory();
    modelDir = '${appDir.path}/asr-models/whisper-tiny-en-int8';
    modelExists = Directory(modelDir).existsSync();

    // 下载测试 WAV 到 sandbox tmp（避免打包进 release 产物）。
    final tmpDir = await getTemporaryDirectory();
    final wavDest = File(p.join(tmpDir.path, '8k.wav'));
    if (!wavDest.existsSync()) {
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse(
          'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny.en'
          '/resolve/main/test_wavs/8k.wav',
        ),
      );
      final response = await request.close();
      final sink = wavDest.openWrite();
      await response.pipe(sink);
      client.close();
    }
    _testWav = wavDest.path;

    // 下载 16kHz 测试 WAV（VAD 测试用）。
    final wav16kDest = File(p.join(tmpDir.path, 'test_speech_16k.wav'));
    if (!wav16kDest.existsSync()) {
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse(
            'https://hf-mirror.com/csukuangfj/sherpa-onnx-whisper-tiny.en'
            '/resolve/main/test_wavs/0.wav',
          ),
        );
        final response = await request.close();
        final sink = wav16kDest.openWrite();
        await response.pipe(sink);
      } finally {
        client.close();
      }
    }
    _testWav16k = wav16kDest.path;
  });

  group('SherpaOnnxEngine 端到端', () {
    testWidgets('Whisper Tiny 转录 8k.wav', (tester) async {
      if (!modelExists) {
        markTestSkipped('模型未下载：$modelDir');
        return;
      }
      if (!File(_testWav).existsSync()) {
        markTestSkipped('测试 WAV 不存在：$_testWav');
        return;
      }

      final engine = SherpaOnnxEngine();

      // 初始化（加载模型，首次较慢）。
      await engine.initialize(
        AsrModelConfig(model: _whisperTinyModel, modelDir: modelDir),
      );
      expect(engine.isReady, isTrue);

      // 第一次转录。
      final result1 = await engine.transcribe(_testWav);
      debugPrint('[ASR Test] text="${result1.text}"');
      debugPrint(
        '[ASR Test] inferenceTime=${result1.inferenceTime.inMilliseconds}ms',
      );

      expect(result1.text, isNotEmpty);
      expect(result1.text.toLowerCase(), contains('hester'));
      expect(result1.inferenceTime.inMilliseconds, greaterThan(0));

      // 第二次转录（Recognizer 已驻留，应更快）。
      final result2 = await engine.transcribe(_testWav);
      debugPrint(
        '[ASR Test] second run: ${result2.inferenceTime.inMilliseconds}ms',
      );

      expect(result2.text, isNotEmpty);
      expect(result2.text.toLowerCase(), contains('hester'));

      await engine.dispose();
      expect(engine.isReady, isFalse);
    });
  });

  group('Silero VAD 端到端', () {
    testWidgets('VAD 对有语音的音频保留合理比例', (tester) async {
      // 下载 VAD 模型。
      final appDir = await getApplicationSupportDirectory();
      final vadDir = Directory('${appDir.path}/asr-models/silero-vad');
      final vadFile = File(p.join(vadDir.path, 'silero_vad.onnx'));
      if (!vadFile.existsSync()) {
        await vadDir.create(recursive: true);
        final vadSpec = asrPublicResourceCatalog[vadModelId]!;
        final client = HttpClient();
        try {
          final request = await client.getUrl(
            vadSpec.fileUri(
              AsrDownloadSource.huggingFace,
              vadSpec.files.single,
            ),
          );
          final response = await request.close();
          final sink = vadFile.openWrite();
          await response.pipe(sink);
        } finally {
          client.close();
        }
      }
      final vadPath = vadFile.path;
      if (!File(_testWav16k).existsSync()) {
        markTestSkipped('测试 WAV 不存在：$_testWav16k');
        return;
      }

      // 读取 16kHz 测试 WAV。
      if (!File(_testWav16k).existsSync()) {
        markTestSkipped('测试 WAV 不存在：$_testWav16k');
        return;
      }
      final audio = readAudioFile(_testWav16k);
      debugPrint(
        '[VAD Test] 原始: ${audio.sampleRate}Hz, '
        '${audio.samples.length} samples, '
        '${(audio.samples.length / audio.sampleRate).toStringAsFixed(1)}s',
      );

      // 降采样到 16kHz（VAD 要求）。
      final Float32List samples16k;
      if (audio.sampleRate == 16000) {
        samples16k = audio.samples;
      } else if (audio.sampleRate > 16000 && audio.sampleRate % 16000 == 0) {
        samples16k = downsample(audio.samples, audio.sampleRate, 16000);
      } else {
        markTestSkipped('测试音频 ${audio.sampleRate}Hz 无法降采样到 16kHz');
        return;
      }
      final beforeSec = samples16k.length / 16000;
      debugPrint('[VAD Test] 降采样后: ${beforeSec.toStringAsFixed(1)}s');

      // 创建 VAD。
      sherpa.initBindings();
      final config = sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: vadPath,
          minSilenceDuration: 0.25,
          minSpeechDuration: 0.5,
          maxSpeechDuration: 60.0,
        ),
        sampleRate: 16000,
        numThreads: 1,
        provider: 'cpu',
        debug: false,
      );
      final vad = sherpa.VoiceActivityDetector(
        config: config,
        bufferSizeInSeconds: 600,
      );

      // 按 windowSize 分块喂入（与官方示例一致）。
      final windowSize = config.sileroVad.windowSize;
      final numIter = samples16k.length ~/ windowSize;

      final segments = <Float32List>[];
      var totalLen = 0;

      for (var i = 0; i < numIter; i++) {
        final start = i * windowSize;
        vad.acceptWaveform(
          Float32List.sublistView(samples16k, start, start + windowSize),
        );
        while (!vad.isEmpty()) {
          final seg = vad.front();
          segments.add(seg.samples);
          totalLen += seg.samples.length;
          vad.pop();
        }
      }
      vad.flush();
      while (!vad.isEmpty()) {
        final seg = vad.front();
        segments.add(seg.samples);
        totalLen += seg.samples.length;
        vad.pop();
      }
      vad.free();

      final afterSec = totalLen / 16000;
      final ratio = afterSec / beforeSec;
      debugPrint(
        '[VAD Test] VAD: ${beforeSec.toStringAsFixed(1)}s → '
        '${afterSec.toStringAsFixed(1)}s '
        '(${(ratio * 100).toStringAsFixed(0)}% 保留)',
      );

      // 有语音的音频至少保留 10%，不应被全部裁掉。
      expect(afterSec, greaterThan(beforeSec * 0.1),
          reason: 'VAD 不应裁掉超过 90% 的有声音频');
      // 也不应完全不裁（测试音频不是纯语音）。
      expect(afterSec, lessThan(beforeSec),
          reason: 'VAD 应裁掉部分静音');
      expect(segments.isNotEmpty, isTrue);
    });
  });
}

/// 标记测试跳过（集成测试中无法用 skip 参数）。
void markTestSkipped(String reason) {
  debugPrint('SKIPPED: $reason');
}
