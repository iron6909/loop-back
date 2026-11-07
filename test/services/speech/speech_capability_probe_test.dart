/// 能力验证流程测试。
///
/// 验证真实的请求内容（随包样本、英语、模型、输出格式）、结论映射与失败传播；
/// 不发真实付费请求，也不触碰用户字幕或练习记录。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/services/speech/speech_capability.dart';
import 'package:echo_loop/services/speech/speech_capability_probe.dart';
import 'package:echo_loop/services/speech/speech_config.dart';
import 'package:echo_loop/services/speech/speech_transcription_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录调用参数的转写客户端替身。
class _RecordingClient implements SpeechTranscriptionClient {
  SpeechTranscriptionResult? result;
  Object? failure;
  Uint8List? audio;
  String? modelId;
  String? fileName;
  Duration? audioDuration;
  SpeechResponseFormat? format;
  bool? requestWordTimestamps;
  SpeechConfig? config;
  int callCount = 0;

  @override
  Future<SpeechTranscriptionResult> transcribe({
    required SpeechConfig config,
    required String apiKey,
    required String modelId,
    required Uint8List audio,
    required String fileName,
    required Duration audioDuration,
    SpeechResponseFormat format = SpeechResponseFormat.verboseJson,
    bool requestWordTimestamps = false,
    String fileContentType = 'audio/wav',
    CancelToken? cancelToken,
  }) async {
    this.config = config;
    callCount++;
    this.modelId = modelId;
    this.audio = audio;
    this.fileName = fileName;
    this.audioDuration = audioDuration;
    this.format = format;
    this.requestWordTimestamps = requestWordTimestamps;
    if (failure case final error?) throw error;
    return result ?? (throw StateError('没有预设结果'));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sample = [1, 2, 3, 4];
  const openRouterConfig = SpeechConfig(
    kind: SpeechProviderKind.openrouter,
    baseUrl: 'https://openrouter.ai/api/v1',
  );
  const customConfig = SpeechConfig(
    kind: SpeechProviderKind.custom,
    baseUrl: 'https://speech.example.com/v1',
  );

  late _RecordingClient client;
  late SpeechCapabilityProbe probe;

  setUp(() {
    client = _RecordingClient();
    probe = SpeechCapabilityProbe(
      client: client,
      sampleLoader: () async => Uint8List.fromList(sample),
      clock: () => DateTime.utc(2026, 11, 7, 12),
    );
  });

  SpeechTranscriptionResult verbose({
    bool segmentsValid = true,
    bool wordsValid = true,
  }) => SpeechTranscriptionResult(
    text: 'Please transcribe this short English sentence.',
    segments: const [
      SpeechTranscriptSegment(start: 0.2, end: 3.4, text: 'Please ...'),
    ],
    words: const [SpeechTranscriptWord(word: 'Please', start: 0.2, end: 0.6)],
    segmentsValid: segmentsValid,
    wordsValid: wordsValid,
    reportedCost: 0.0004,
  );

  test('上传随包英语样本并请求字幕时间戳', () async {
    client.result = verbose();

    await probe.run(
      config: openRouterConfig,
      apiKey: 'sk-speech-test',
      modelId: 'openai/whisper-large-v3',
      credentialVersion: 'credential-a',
    );

    expect(client.audio, sample);
    expect(client.callCount, 1);
    expect(client.fileName, SpeechCapabilityProbe.sampleFileName);
    expect(client.audioDuration, SpeechCapabilityProbe.sampleDuration);
    expect(client.modelId, 'openai/whisper-large-v3');
    expect(client.format, SpeechResponseFormat.verboseJson);
    expect(client.requestWordTimestamps, isTrue);
  });

  test('一次请求同时给出文本、字幕与词时间戳结论', () async {
    client.result = verbose();

    final capability = await probe.run(
      config: openRouterConfig,
      apiKey: 'sk-speech-test',
      modelId: 'openai/whisper-large-v3',
      credentialVersion: 'credential-a',
    );

    expect(capability.text, isTrue);
    expect(capability.segments, isTrue);
    expect(capability.wordTimestamps, isTrue);
    expect(capability.reportedCost, 0.0004);
    expect(capability.validatedAt, DateTime.utc(2026, 11, 7, 12));
    expect(
      capability.identity,
      SpeechCapability.identityFor(
        kind: SpeechProviderKind.openrouter,
        baseUrl: 'https://openrouter.ai/api/v1',
        modelId: 'openai/whisper-large-v3',
        credentialVersion: 'credential-a',
      ),
    );
  });

  test('自定义服务不请求词时间戳参数，词能力不算已确认', () async {
    client.result = verbose();

    final capability = await probe.run(
      config: customConfig,
      apiKey: 'sk-speech-test',
      modelId: 'whisper-1',
      credentialVersion: 'credential-a',
    );

    expect(client.requestWordTimestamps, isFalse);
    expect(capability.wordTimestamps, isFalse);
    expect(capability.segments, isTrue);
  });

  test('只有文本没有合法片段时字幕不可用', () async {
    client.result = verbose(segmentsValid: false, wordsValid: false);

    final capability = await probe.run(
      config: openRouterConfig,
      apiKey: 'sk-speech-test',
      modelId: 'openai/whisper-large-v3',
      credentialVersion: 'credential-a',
    );

    expect(capability.text, isTrue);
    expect(capability.segments, isFalse);
    expect(capability.wordTimestamps, isFalse);
  });

  test('请求失败原样抛出，不伪造已验证', () async {
    client.failure = const SpeechTranscriptionException(
      SpeechTranscriptionErrorKind.insufficientBalance,
    );

    await expectLater(
      probe.run(
        config: openRouterConfig,
        apiKey: 'sk-speech-test',
        modelId: 'openai/whisper-large-v3',
        credentialVersion: 'credential-a',
      ),
      throwsA(
        isA<SpeechTranscriptionException>().having(
          (error) => error.kind,
          'kind',
          SpeechTranscriptionErrorKind.insufficientBalance,
        ),
      ),
    );
  });

  test('随包样本是 4 秒 16 kHz 单声道 WAV', () async {
    final bytes = await File(SpeechCapabilityProbe.sampleAssetPath).readAsBytes();
    expect(bytes.length, 128044);
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');

    final header = ByteData.sublistView(bytes);
    // fmt 块的三个关键字段：通道数、采样率、位深。
    expect(header.getUint16(22, Endian.little), 1);
    expect(header.getUint32(24, Endian.little), 16000);
    expect(header.getUint16(34, Endian.little), 16);
    final seconds = (bytes.length - 44) / (16000 * 2);
    expect(seconds, SpeechCapabilityProbe.sampleDuration.inSeconds);
  });
}
