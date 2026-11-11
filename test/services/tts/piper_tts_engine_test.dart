import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:loop_back/services/tts/piper_model_manager.dart'
    show PiperModelPaths;
import 'package:loop_back/services/tts/piper_synthesizer.dart';
import 'package:loop_back/services/tts/piper_tts_engine.dart';
import 'package:loop_back/services/tts/piper_model_catalog.dart';
import 'package:loop_back/services/tts/tts_engine.dart';

/// 记录调用并按需写假 wav 的 fake 合成器。
class _FakeSynth implements PiperNativeSynthesizer {
  _FakeSynth({this.failSynthesis = false});

  final bool failSynthesis;
  int initCount = 0;
  int disposeCount = 0;
  String? lastVoiceId;
  String? lastText;
  String? lastModelPath;
  String? lastOutputPath;

  @override
  Future<void> init({int numThreads = 2}) async {
    initCount++;
  }

  @override
  Future<int?> synthesize({
    required PiperModelPaths paths,
    required String voiceId,
    required String text,
    required double speed,
    required String outputPath,
  }) async {
    lastVoiceId = voiceId;
    lastText = text;
    lastModelPath = paths.model;
    lastOutputPath = outputPath;
    if (failSynthesis) return null;
    await File(outputPath).writeAsBytes(const [0, 1, 2, 3]);
    return 22050;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

void main() {
  late Directory outDir;

  // resolvePaths 回显 voiceId 到 model 路径，便于断言「按音色取了对应模型」。
  PiperTtsEngine build(_FakeSynth synth) => PiperTtsEngine(
    resolvePaths: (voiceId) async => PiperModelPaths(
      model: '/m/$voiceId.onnx',
      tokens: '/m/$voiceId/tokens.txt',
      dataDir: '/m/$voiceId/espeak-ng-data',
    ),
    synthesizerFactory: () => synth,
  );

  setUp(() async {
    outDir = await Directory.systemTemp.createTemp('piper-engine-test');
  });
  tearDown(() async {
    if (await outDir.exists()) await outDir.delete(recursive: true);
  });

  test('synthesize 产出 wav，返回正确路径/格式/采样率', () async {
    final synth = _FakeSynth();
    final engine = build(synth);
    await engine.applyConfig(
      TtsSpeechConfig(languageTag: 'en-US', voiceName: piperDefaultVoiceUs),
    );

    final result = await engine.synthesize(
      'hello',
      outputDir: outDir.path,
      baseName: 'abc',
    );

    expect(result, isNotNull);
    expect(result!.format, 'wav');
    expect(result.filePath, p.join(outDir.path, 'abc.wav'));
    expect(result.sampleRate, 22050);
    expect(File(result.filePath).existsSync(), isTrue);
    expect(synth.lastText, 'hello');
    expect(synth.lastVoiceId, piperDefaultVoiceUs);
  });

  test('显式 config 的 voiceName 优先于环境态（§7.18 防竞态）', () async {
    final synth = _FakeSynth();
    final engine = build(synth);
    await engine.applyConfig(
      TtsSpeechConfig(languageTag: 'en-US', voiceName: piperDefaultVoiceUs),
    );

    final ukVoice = piperDefaultVoiceUk;
    await engine.synthesize(
      'x',
      outputDir: outDir.path,
      baseName: 'b',
      config: TtsSpeechConfig(languageTag: 'en-GB', voiceName: ukVoice),
    );
    expect(synth.lastVoiceId, ukVoice);
    expect(synth.lastModelPath, '/m/$ukVoice.onnx');
  });

  test('未知 voiceName → 按语言标签回退该口音默认音色', () async {
    final synth = _FakeSynth();
    final engine = build(synth);
    await engine.applyConfig(
      const TtsSpeechConfig(languageTag: 'en-GB', voiceName: 'ghost'),
    );
    await engine.synthesize('x', outputDir: outDir.path, baseName: 'b');
    expect(synth.lastVoiceId, piperDefaultVoiceUk);
  });

  test('合成失败（synth 返回 null）→ engine 返回 null', () async {
    final synth = _FakeSynth(failSynthesis: true);
    final engine = build(synth);
    await engine.applyConfig(
      TtsSpeechConfig(languageTag: 'en-US', voiceName: piperDefaultVoiceUs),
    );
    final result = await engine.synthesize(
      'x',
      outputDir: outDir.path,
      baseName: 'b',
    );
    expect(result, isNull);
  });

  test('initialize 幂等：多次 synthesize 只 init 一次', () async {
    final synth = _FakeSynth();
    final engine = build(synth);
    await engine.synthesize('x', outputDir: outDir.path, baseName: 'b');
    await engine.synthesize('y', outputDir: outDir.path, baseName: 'c');
    expect(synth.initCount, 1);
  });

  test('speakLive 返回 false（不抛）', () async {
    expect(await build(_FakeSynth()).speakLive('x'), isFalse);
  });

  test('dispose 转发并允许重新初始化', () async {
    final synth = _FakeSynth();
    final engine = build(synth);
    await engine.synthesize('x', outputDir: outDir.path, baseName: 'b');
    await engine.dispose();
    expect(synth.disposeCount, 1);
    await engine.synthesize('y', outputDir: outDir.path, baseName: 'c');
    expect(synth.initCount, 2);
  });
}
