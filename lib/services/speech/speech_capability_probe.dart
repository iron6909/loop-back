/// 用随包英语短样本主动验证在线模型的能力。
///
/// 样本随包、由用户主动触发，绝不使用用户录音；一次请求同时得到文本、片段与
/// （适用时）词时间戳结论，避免为同一配置重复付费。目录刷新或文字聊天成功都不
/// 能代替这里的结论。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'speech_capability.dart';
import 'speech_config.dart';
import 'speech_transcription_client.dart';

/// 一次真实能力验证。
class SpeechCapabilityProbe {
  SpeechCapabilityProbe({
    SpeechTranscriptionClient? client,
    Future<Uint8List> Function()? sampleLoader,
    DateTime Function()? clock,
  }) : _client = client ?? SpeechTranscriptionClient(),
       _sampleLoader = sampleLoader ?? _loadBundledSample,
       _clock = clock ?? DateTime.now;

  final SpeechTranscriptionClient _client;
  final Future<Uint8List> Function() _sampleLoader;
  final DateTime Function() _clock;

  /// 随包样本：en-US 合成语音「Please transcribe this short English sentence.」，
  /// 16 kHz 单声道 16 bit WAV，正好 4 秒（128044 字节）。
  ///
  /// 由本机 Windows SAPI 英语语音合成，属于项目自有内容，不含第三方版权素材；
  /// 不录制用户声音。换样本时必须同步改 [sampleDuration]，样本测试会指明大小变化。
  static const sampleAssetPath = 'assets/audio/speech_probe_en.wav';
  static const sampleFileName = 'speech_probe_en.wav';
  static const sampleDuration = Duration(seconds: 4);

  static Future<Uint8List> _loadBundledSample() async =>
      (await rootBundle.load(sampleAssetPath)).buffer.asUint8List();

  /// 对该配置的所选模型做一次验证并返回结论。
  ///
  /// 字幕能力要请求 `verbose_json` 才有片段时间戳；词时间戳参数只发给已确认
  /// 支持的配置：OpenRouter 预设在规格里已核实，自定义服务首次验证不请求，
  /// 避免因参数不被接受而让整次验证失败。
  Future<SpeechCapability> run({
    required SpeechConfig config,
    required String apiKey,
    required String modelId,
    required String? credentialVersion,
    CancelToken? cancelToken,
  }) async {
    final audio = await _sampleLoader();
    final requestWordTimestamps =
        config.kind == SpeechProviderKind.openrouter;
    final result = await _client.transcribe(
      config: config,
      apiKey: apiKey,
      modelId: modelId,
      audio: audio,
      fileName: sampleFileName,
      audioDuration: sampleDuration,
      format: SpeechResponseFormat.verboseJson,
      requestWordTimestamps: requestWordTimestamps,
      cancelToken: cancelToken,
    );
    return SpeechCapability(
      identity: SpeechCapability.identityFor(
        kind: config.kind,
        baseUrl: config.baseUrl,
        modelId: modelId,
        credentialVersion: credentialVersion,
      ),
      text: result.text.trim().isNotEmpty,
      segments: result.segmentsValid,
      wordTimestamps: requestWordTimestamps && result.wordsValid,
      validatedAt: _clock(),
      reportedCost: result.reportedCost,
    );
  }
}
