/// 单块在线跟读转写的请求前判定与上传测试。
///
/// 只替换网络边界：用真实文件证明格式、大小与时长判定（单块内直接上传，超出则
/// 交给分块转写），用假 adapter 证明请求形状与请求次数。测试不构造真实录音，
/// 也不发任何付费请求。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/services/speech/practice_online_transcriber.dart';
import 'package:echo_loop/services/speech/speech_config.dart';
import 'package:echo_loop/services/speech/speech_transcription_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录请求并按队列返回预设响应的 adapter。
class _FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<Uint8List> bodies = [];
  final List<ResponseBody> _responses = [];

  void enqueueJson(Object payload) {
    _responses.add(
      ResponseBody.fromString(
        jsonEncode(payload),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requestStream != null) {
      bodies.add(
        Uint8List.fromList([
          for (final chunk in await requestStream.toList()) ...chunk,
        ]),
      );
    }
    if (_responses.isEmpty) throw StateError('没有预设响应');
    return _responses.removeAt(0);
  }

  @override
  void close({bool force = false}) {}
}

const _openRouterBaseUrl = 'https://openrouter.ai/api/v1';

SpeechConfig _config() => const SpeechConfig(
  kind: SpeechProviderKind.openrouter,
  baseUrl: _openRouterBaseUrl,
);

/// 生成 16 kHz 单声道 PCM16 WAV；[duration] 决定样本数。
Uint8List _wav(Duration duration, {int sampleRate = 16000}) {
  final samples = sampleRate * duration.inMilliseconds ~/ 1000;
  final dataSize = samples * 2;
  final bytes = ByteData(44 + dataSize);
  void writeAscii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataSize, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  bytes.setUint32(40, dataSize, Endian.little);
  return bytes.buffer.asUint8List();
}

/// 取 multipart 请求里的字段值；缺失时返回 null。
String? _field(RequestOptions options, Uint8List body, String name) {
  final text = latin1.decode(body, allowInvalid: true);
  final marker = 'name="$name"';
  final start = text.indexOf(marker);
  if (start < 0) return null;
  final valueStart = text.indexOf('\r\n\r\n', start) + 4;
  final valueEnd = text.indexOf('\r\n', valueStart);
  return text.substring(valueStart, valueEnd);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('shadowing_online_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<String> writeRecording(String name, Uint8List bytes) async {
    final file = File('${tempDir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  Future<PracticeRecordingUpload> prepareUpload(
    PracticeOnlineTranscriber transcriber,
    String path,
  ) async {
    final access = await transcriber.prepare(path);
    return switch (access) {
      PracticeRecordingUpload() => access,
      PracticeRecordingNeedsChunking() => fail('应可直接上传'),
    };
  }

  group('请求前检查', () {
    test('缺失文件明确拒绝', () async {
      final transcriber = PracticeOnlineTranscriber(
        client: SpeechTranscriptionClient(dio: Dio()),
      );
      await expectLater(
        transcriber.prepare('${tempDir.path}/missing.wav'),
        throwsA(
          isA<PracticeRecordingRejected>().having(
            (error) => error.rejection,
            'rejection',
            PracticeRecordingRejection.fileMissing,
          ),
        ),
      );
    });

    test('不认识的容器明确拒绝，不当作音频上传', () async {
      final path = await writeRecording('note.txt', Uint8List(2048));
      final transcriber = PracticeOnlineTranscriber(
        client: SpeechTranscriptionClient(dio: Dio()),
      );
      await expectLater(
        transcriber.prepare(path),
        throwsA(
          isA<PracticeRecordingRejected>().having(
            (error) => error.rejection,
            'rejection',
            PracticeRecordingRejection.unsupportedFormat,
          ),
        ),
      );
    });

    test('超出单块时长时交给分块转写，不截断录音', () async {
      final path = await writeRecording(
        'long.wav',
        _wav(const Duration(minutes: 3)),
      );
      final transcriber = PracticeOnlineTranscriber(
        client: SpeechTranscriptionClient(dio: Dio()),
      );
      final access = await transcriber.prepare(path);

      expect(access, isA<PracticeRecordingNeedsChunking>());
      expect(switch (access) {
        PracticeRecordingNeedsChunking() => access.duration,
        PracticeRecordingUpload() => fail('超出单块时不应直接上传'),
      }, const Duration(minutes: 3));
    });

    test('超出单块字节上限时交给分块转写，不整份读入内存', () async {
      final big = Uint8List(practiceOnlineMaxBytes + 1);
      // 文件头保持合法容器，只有大小超出单块上限。
      big.setAll(0, _wav(Duration.zero).sublist(0, 12));
      final path = await writeRecording('huge.wav', big);
      final transcriber = PracticeOnlineTranscriber(
        client: SpeechTranscriptionClient(dio: Dio()),
      );

      final access = await transcriber.prepare(path);

      expect(access, isA<PracticeRecordingNeedsChunking>());
      expect(
        switch (access) {
          PracticeRecordingNeedsChunking() => access.duration,
          PracticeRecordingUpload() => fail('超出单块时不应直接上传'),
        },
        isNull,
        reason: '时长交给分块转写测长',
      );
    });

    test('合法 WAV 得到可上传的字节、文件名、媒体类型与真实时长', () async {
      final path = await writeRecording(
        'take.wav',
        _wav(const Duration(seconds: 3)),
      );
      final transcriber = PracticeOnlineTranscriber(
        client: SpeechTranscriptionClient(dio: Dio()),
      );

      final upload = await prepareUpload(transcriber, path);

      expect(upload.fileName, 'take.wav');
      expect(upload.contentType, 'audio/wav');
      expect(upload.duration.inMilliseconds, closeTo(3000, 2));
      expect(upload.bytes, isNotEmpty);
    });
  });

  group('单次上传', () {
    test('用跟读所选模型请求文本转写，只发一次请求', () async {
      final adapter = _FakeAdapter()..enqueueJson({'text': ' hello there '});
      final client = SpeechTranscriptionClient(
        dio: Dio()..httpClientAdapter = adapter,
      );
      final transcriber = PracticeOnlineTranscriber(client: client);
      final path = await writeRecording(
        'take.wav',
        _wav(const Duration(seconds: 2)),
      );
      final upload = await prepareUpload(transcriber, path);
      final progress = <double>[];

      final result = await transcriber.transcribe(
        config: _config(),
        apiKey: 'sk-shadowing-test',
        modelId: 'openai/whisper-1',
        recording: upload,
        onProgress: progress.add,
      );

      expect(result.text, 'hello there');
      expect(adapter.requests, hasLength(1));
      final request = adapter.requests.single;
      expect(request.uri.path, '/api/v1/audio/transcriptions');
      expect(request.headers['Authorization'], 'Bearer sk-shadowing-test');
      expect(
        _field(request, adapter.bodies.single, 'model'),
        'openai/whisper-1',
      );
      expect(_field(request, adapter.bodies.single, 'language'), 'en');
      expect(
        _field(request, adapter.bodies.single, 'response_format'),
        'json',
        reason: '跟读只需要文本，不请求片段时间戳',
      );
      expect(_field(request, adapter.bodies.single, 'file'), isNotNull);
      expect(progress, isNotEmpty, reason: '上传进度用于界面显示');
    });

    test('供应商报告的未知费用保持未知，不按免费处理', () async {
      final adapter = _FakeAdapter()..enqueueJson({'text': 'hi'});
      final client = SpeechTranscriptionClient(
        dio: Dio()..httpClientAdapter = adapter,
      );
      final transcriber = PracticeOnlineTranscriber(client: client);
      final upload = await prepareUpload(
        transcriber,
        await writeRecording('take.wav', _wav(const Duration(seconds: 1))),
      );

      final result = await transcriber.transcribe(
        config: _config(),
        apiKey: 'sk-shadowing-test',
        modelId: 'openai/whisper-1',
        recording: upload,
      );

      expect(result.reportedCost, isNull);
    });
  });
}
