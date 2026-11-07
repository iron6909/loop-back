/// 练习录音分块转写的行为测试：顺序分块、边界局部合并、静音跳过、失败续试与取消。
///
/// 只替换不可控边界（转码、网络）：录音文件是真实临时文件，分块规划与文本合并
/// 走真实代码。测试不发真实付费请求，也不使用真实 Key。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;
import 'package:echo_loop/features/audio_import/audio_transcode_service.dart';
import 'package:echo_loop/models/recognition_selection.dart';
import 'package:echo_loop/services/speech/practice_chunk_transcriber.dart';
import 'package:echo_loop/services/speech/speech_config.dart';
import 'package:echo_loop/services/speech/speech_transcription_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _identity = 'openrouter|https://openrouter.ai/api/v1|openai/whisper-1|v1';

const _config = SpeechConfig(
  kind: SpeechProviderKind.openrouter,
  baseUrl: 'https://openrouter.ai/api/v1',
  onlineModels: {RecognitionPurpose.shadowing: 'openai/whisper-1'},
);

/// 16 kHz 单声道 16 bit PCM；[amplitude] 为 0 时是确认无声的块。
Uint8List _pcmBytes(Duration duration, {int amplitude = 8000}) {
  final samples = duration.inMicroseconds * 16000 ~/ 1000000;
  final bytes = Uint8List(samples * 2);
  for (var i = 0; i < samples; i++) {
    final value = amplitude == 0 ? 0 : (i.isEven ? amplitude : -amplitude);
    bytes[i * 2] = value & 0xff;
    bytes[i * 2 + 1] = (value >> 8) & 0xff;
  }
  return bytes;
}

/// 假转码：记录每次区间提取，按区间时长写出 PCM；`duration` 为 null 时写整段测长结果。
class _FakeTranscode extends AudioTranscodeService {
  _FakeTranscode({required this.totalDuration});

  /// 整段录音时长：测长提取（`duration == null`）按它写 PCM。
  final Duration totalDuration;

  final List<({Duration start, Duration? duration})> ranges = [];

  /// 这些起点提取出的块写成静音，用来验证确认无声的块被跳过。
  final Set<Duration> silentStarts = {};

  /// 为真时所有提取都失败，用来验证解码失败。
  bool failAll = false;

  final List<int> cancelledSessions = [];

  @override
  Future<bool> transcodeRangeToPcmWav16k({
    required File source,
    required File output,
    required Duration start,
    Duration? duration,
    void Function(int sessionId)? onSessionStarted,
  }) async {
    ranges.add((start: start, duration: duration));
    onSessionStarted?.call(ranges.length);
    if (failAll) return false;
    final span = duration ?? totalDuration;
    final amplitude = silentStarts.contains(start) ? 0 : 8000;
    await output.parent.create(recursive: true);
    await output.writeAsBytes(_pcmBytes(span, amplitude: amplitude));
    return true;
  }

  @override
  void cancelSession(int sessionId) => cancelledSessions.add(sessionId);
}

/// 受控转写客户端：记录请求形状与上传时长，按调用序号返回文本或失败。
class _FakeClient extends SpeechTranscriptionClient {
  final List<({Duration duration, SpeechResponseFormat format, bool words})>
  calls = [];

  Future<SpeechTranscriptionResult> Function(int index)? onCall;

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
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    final index = calls.length;
    calls.add((
      duration: audioDuration,
      format: format,
      words: requestWordTimestamps,
    ));
    final handler = onCall;
    if (handler != null) return handler(index);
    return SpeechTranscriptionResult(text: 'part ${index + 1}');
  }
}

typedef _Env = ({
  PracticeChunkTranscriber transcriber,
  _FakeClient client,
  _FakeTranscode transcode,
});

_Env _build({required Duration total}) {
  final transcode = _FakeTranscode(totalDuration: total);
  final client = _FakeClient();
  return (
    transcriber: PracticeChunkTranscriber(client: client, transcode: transcode),
    client: client,
    transcode: transcode,
  );
}

void main() {
  late Directory tempDir;
  late File recording;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('practice_chunk_test');
    recording = File('${tempDir.path}/take.wav');
    await recording.writeAsBytes(Uint8List(1024));
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('超出单块时顺序分块，只请求文本并按硬切边界局部去重', () async {
    final env = _build(total: const Duration(minutes: 3, seconds: 20));
    env.client.onCall = (index) async => SpeechTranscriptionResult(
      text: index == 0
          ? 'we should keep the change'
          : 'keep the change and move on',
      reportedCost: 0.0002,
    );

    final session = await env.transcriber.plan(
      recordingPath: recording.path,
      identity: _identity,
      audioDuration: const Duration(minutes: 3, seconds: 20),
    );
    expect(session.chunks, hasLength(2), reason: '三分钟录音切成两块');
    expect(session.chunks.first.hardCut, isTrue, reason: '没有静音时硬切');

    await env.transcriber.run(
      session: session,
      config: _config,
      apiKey: 'sk-test',
      modelId: 'openai/whisper-1',
      cancelToken: CancelToken(),
    );

    expect(env.client.calls, hasLength(2), reason: '顺序上传每块一次');
    expect(
      env.client.calls.every(
        (call) => call.format == SpeechResponseFormat.json,
      ),
      isTrue,
      reason: '纯文本用途不请求片段时间戳',
    );
    expect(
      env.client.calls.every((call) => call.words == false),
      isTrue,
      reason: '纯文本用途不请求词时间戳',
    );
    // 硬切重叠区里重复识别的词只保留一份，材料内容不丢。
    expect(session.text, 'we should keep the change and move on');
    expect(session.completedCount, 2);
    expect(session.reportedCost, closeTo(0.0004, 1e-9));
    await session.discardTemp();
  });

  test('失败停在当前块，续试只重发未完成块', () async {
    final env = _build(total: const Duration(minutes: 5));
    final texts = ['first part', 'second part', 'third part'];
    env.client.onCall = (index) async {
      if (index == 1) {
        throw const SpeechTranscriptionException(
          SpeechTranscriptionErrorKind.timeout,
        );
      }
      return SpeechTranscriptionResult(text: texts[index == 0 ? 0 : index - 1]);
    };

    final session = await env.transcriber.plan(
      recordingPath: recording.path,
      identity: _identity,
      audioDuration: const Duration(minutes: 5),
    );
    expect(session.chunks, hasLength(3));

    await expectLater(
      env.transcriber.run(
        session: session,
        config: _config,
        apiKey: 'sk-test',
        modelId: 'openai/whisper-1',
        cancelToken: CancelToken(),
      ),
      throwsA(
        isA<PracticeChunkFailure>()
            .having(
              (error) => error.reason,
              'reason',
              PracticeChunkFailureReason.requestFailed,
            )
            .having((error) => error.failedChunk?.index, 'failedChunk', 1)
            .having(
              (error) => error.mayHaveBeenCharged,
              'mayHaveBeenCharged',
              isTrue,
            )
            .having(
              (error) => error.cause,
              'cause',
              isA<SpeechTranscriptionException>(),
            ),
      ),
    );

    expect(env.client.calls, hasLength(2), reason: '失败后不再请求后续块');
    expect(session.completedCount, 1, reason: '已成功块保留在会话里');

    // 用户手动续试：只发失败块与后面未完成的块，已成功块不再上传。
    await env.transcriber.run(
      session: session,
      config: _config,
      apiKey: 'sk-test',
      modelId: 'openai/whisper-1',
      cancelToken: CancelToken(),
    );

    expect(env.client.calls, hasLength(4), reason: '续试只补两块');
    expect(session.text, 'first part second part third part');
    await session.discardTemp();
  });

  test('确认无声的块跳过上传，整份无声报无可识别语音', () async {
    final env = _build(total: const Duration(minutes: 3, seconds: 20));
    final session = await env.transcriber.plan(
      recordingPath: recording.path,
      identity: _identity,
      audioDuration: const Duration(minutes: 3, seconds: 20),
    );
    env.transcode.silentStarts.add(session.chunks[1].start);

    await env.transcriber.run(
      session: session,
      config: _config,
      apiKey: 'sk-test',
      modelId: 'openai/whisper-1',
      cancelToken: CancelToken(),
    );

    expect(env.client.calls, hasLength(1), reason: '无声块不浪费一次请求');
    expect(session.completedCount, 2, reason: '无声块也算已处理');
    expect(session.text, 'part 1');
    await session.discardTemp();

    final silentEnv = _build(total: const Duration(minutes: 3, seconds: 20));
    final silentSession = await silentEnv.transcriber.plan(
      recordingPath: recording.path,
      identity: _identity,
      audioDuration: const Duration(minutes: 3, seconds: 20),
    );
    silentEnv.transcode.silentStarts.addAll(
      silentSession.chunks.map((chunk) => chunk.start),
    );
    await expectLater(
      silentEnv.transcriber.run(
        session: silentSession,
        config: _config,
        apiKey: 'sk-test',
        modelId: 'openai/whisper-1',
        cancelToken: CancelToken(),
      ),
      throwsA(
        isA<PracticeChunkFailure>().having(
          (error) => error.reason,
          'reason',
          PracticeChunkFailureReason.noSpeech,
        ),
      ),
    );
    expect(silentEnv.client.calls, isEmpty, reason: '整份无声不上传');
    await silentSession.discardTemp();
  });

  test('取消后不再发下一块', () async {
    final env = _build(total: const Duration(minutes: 5));
    final token = CancelToken();
    env.client.onCall = (index) async {
      if (index == 0) {
        token.cancel();
        throw const SpeechTranscriptionException(
          SpeechTranscriptionErrorKind.cancelled,
        );
      }
      return SpeechTranscriptionResult(text: 'part ${index + 1}');
    };

    final session = await env.transcriber.plan(
      recordingPath: recording.path,
      identity: _identity,
      audioDuration: const Duration(minutes: 5),
    );

    await expectLater(
      env.transcriber.run(
        session: session,
        config: _config,
        apiKey: 'sk-test',
        modelId: 'openai/whisper-1',
        cancelToken: token,
      ),
      throwsA(
        isA<PracticeChunkFailure>().having(
          (error) => error.reason,
          'reason',
          PracticeChunkFailureReason.cancelled,
        ),
      ),
    );
    expect(env.client.calls, hasLength(1), reason: '取消后不开始下一块');
    await session.discardTemp();
  });

  test('配置身份变化时停止后续请求，旧块不拼进新配置', () async {
    final env = _build(total: const Duration(minutes: 5));
    final session = await env.transcriber.plan(
      recordingPath: recording.path,
      identity: _identity,
      audioDuration: const Duration(minutes: 5),
    );

    await expectLater(
      env.transcriber.run(
        session: session,
        config: _config,
        apiKey: 'sk-test',
        modelId: 'openai/whisper-1',
        cancelToken: CancelToken(),
        readCurrentIdentity: () async => 'other-identity',
      ),
      throwsA(
        isA<PracticeChunkFailure>().having(
          (error) => error.reason,
          'reason',
          PracticeChunkFailureReason.configChanged,
        ),
      ),
    );
    expect(env.client.calls, isEmpty, reason: '配置已变化就不再上传');
    await session.discardTemp();
  });

  test('无法解码时明确失败，不发出任何请求', () async {
    final env = _build(total: const Duration(minutes: 3));
    env.transcode.failAll = true;

    await expectLater(
      env.transcriber.plan(recordingPath: recording.path, identity: _identity),
      throwsA(
        isA<PracticeChunkFailure>().having(
          (error) => error.reason,
          'reason',
          PracticeChunkFailureReason.decodeFailed,
        ),
      ),
    );
    expect(env.client.calls, isEmpty);
  });

  test('丢弃会话时删除整段提取出的临时音频', () async {
    final env = _build(total: const Duration(minutes: 3));
    final session = await env.transcriber.plan(
      recordingPath: recording.path,
      identity: _identity,
      audioDuration: const Duration(minutes: 3),
    );
    expect(await session.tempDir.exists(), isTrue);

    await session.discardTemp();

    expect(await session.tempDir.exists(), isFalse, reason: '临时音频不留在磁盘');
  });
}
