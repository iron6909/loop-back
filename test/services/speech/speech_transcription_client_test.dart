/// 在线转写客户端测试。
///
/// 用假 adapter 而不是 mock 客户端：只有真实 Dio 实例才能证明 multipart 的实际
/// 形状（字段名、文件、Authorization）与真实状态码到错误分类的映射。测试不发任何
/// 真实请求，也不触碰用户字幕或练习结果。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/services/speech/speech_config.dart';
import 'package:echo_loop/services/speech/speech_transcription_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录请求并按队列返回预设响应的 adapter。
class _FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<Uint8List> bodies = [];
  final List<Object> _responses = [];

  int get requestCount => requests.length;

  void enqueueJson(Object payload, {int status = 200}) {
    _responses.add(
      ResponseBody.fromString(
        jsonEncode(payload),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
  }

  void enqueueText(String body, {int status = 200}) {
    _responses.add(
      ResponseBody.fromString(
        body,
        status,
        headers: {
          Headers.contentTypeHeader: ['text/plain'],
        },
      ),
    );
  }

  void enqueueError(DioExceptionType type) {
    _responses.add(DioException(requestOptions: RequestOptions(path: ''), type: type));
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (_responses.isEmpty) throw StateError('没有预设响应');
    final next = _responses.removeAt(0);
    if (next is DioException) {
      throw DioException(requestOptions: options, type: next.type);
    }
    final body = next as ResponseBody;
    // 请求体是流时必须先读完；multipart 文件在交给 adapter 前已经定稿，
    // 因此把实际发出的字节留在这里给测试断言，而不是事后重新 finalize。
    if (requestStream != null) {
      final chunks = await requestStream.toList();
      bodies.add(Uint8List.fromList([for (final chunk in chunks) ...chunk]));
    }
    return body;
  }

  @override
  void close({bool force = false}) {}
}

/// 取 multipart 请求里的字段值；缺失时返回 null。
Future<String?> _field(RequestOptions options, String name) async {
  final data = options.data;
  if (data is! FormData) return null;
  for (final field in data.fields) {
    if (field.key == name) return field.value;
  }
  return null;
}

/// 取 multipart 请求里的文件条目；缺失时返回 null。
MapEntry<String, MultipartFile>? _fileEntry(
  RequestOptions options,
  String name,
) {
  final data = options.data;
  if (data is! FormData) return null;
  for (final entry in data.files) {
    if (entry.key == name) return entry;
  }
  return null;
}

/// 实际发出的字节里是否包含 [needle]。
bool _contains(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var matches = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

void main() {
  late _FakeAdapter adapter;
  late Dio dio;

  const audio = [1, 2, 3, 4, 5, 6, 7, 8];
  const duration = Duration(seconds: 4);
  const openRouterConfig = SpeechConfig(
    kind: SpeechProviderKind.openrouter,
    baseUrl: 'https://openrouter.ai/api/v1',
  );

  setUp(() {
    adapter = _FakeAdapter();
    dio = Dio()..httpClientAdapter = adapter;
  });

  SpeechTranscriptionClient client() => SpeechTranscriptionClient(dio: dio);

  Future<SpeechTranscriptionResult> transcribe({
    SpeechConfig config = openRouterConfig,
    String apiKey = 'sk-speech-test',
    String modelId = 'openai/whisper-large-v3',
    SpeechResponseFormat format = SpeechResponseFormat.verboseJson,
    bool requestWordTimestamps = false,
  }) => client().transcribe(
    config: config,
    apiKey: apiKey,
    modelId: modelId,
    audio: Uint8List.fromList(audio),
    fileName: 'speech_probe_en.wav',
    audioDuration: duration,
    format: format,
    requestWordTimestamps: requestWordTimestamps,
  );

  group('请求形状', () {
    test('multipart 上传文件、模型、英语与需要片段时间戳的输出格式', () async {
      adapter.enqueueJson({
        'text': 'Hello world.',
        'duration': 4.0,
        'segments': [
          {'start': 0.2, 'end': 3.4, 'text': 'Hello world.'},
        ],
      });

      await transcribe(requestWordTimestamps: true);

      expect(adapter.requestCount, 1);
      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.toString(), 'https://openrouter.ai/api/v1/audio/transcriptions');
      expect(request.headers['Authorization'], 'Bearer sk-speech-test');
      expect(await _field(request, 'model'), 'openai/whisper-large-v3');
      expect(await _field(request, 'language'), 'en');
      expect(await _field(request, 'response_format'), 'verbose_json');
      expect(await _field(request, 'timestamp_granularities[]'), 'word');
      final file = _fileEntry(request, 'file');
      expect(file?.value.filename, 'speech_probe_en.wav');
      expect(file?.value.length, audio.length);
      // 真正发出的 multipart 正文里必须有音频字节与文件名。
      expect(_contains(adapter.bodies.single, audio), isTrue);
      expect(
        _contains(adapter.bodies.single, utf8.encode('speech_probe_en.wav')),
        isTrue,
      );
    });

    test('文本用途请求 JSON 文本，不携带词时间戳参数', () async {
      adapter.enqueueJson({'text': 'Hello world.'});

      final result = await transcribe(format: SpeechResponseFormat.json);

      final request = adapter.requests.single;
      expect(await _field(request, 'response_format'), 'json');
      expect(await _field(request, 'timestamp_granularities[]'), isNull);
      expect(result.text, 'Hello world.');
    });

    test('未请求词时间戳时 verbose 响应里的词不成为已确认能力', () async {
      adapter.enqueueJson({
        'text': 'Hello world.',
        'duration': 4.0,
        'segments': [
          {'start': 0.2, 'end': 3.4, 'text': 'Hello world.'},
        ],
        'words': [
          {'word': 'Hello', 'start': 0.2, 'end': 0.9},
        ],
      });

      final result = await transcribe();

      expect(result.segmentsValid, isTrue);
      expect(result.wordsValid, isFalse);
    });

    test('缺少 Key 时不发请求', () async {
      await expectLater(
        transcribe(apiKey: '  '),
        throwsA(
          isA<SpeechTranscriptionException>().having(
            (error) => error.kind,
            'kind',
            SpeechTranscriptionErrorKind.unauthorized,
          ),
        ),
      );
      expect(adapter.requestCount, 0);
    });
  });

  group('结果映射', () {
    test('映射文本、片段、词时间戳与服务端报告的音频时长', () async {
      adapter.enqueueJson({
        'text': '  Hello world.  ',
        'duration': 4.0,
        'usage': {'cost': 0.00012, 'seconds': 4},
        'segments': [
          {'start': 0.2, 'end': 1.4, 'text': 'Hello'},
          {'start': 1.4, 'end': 3.4, 'text': 'world.'},
        ],
        'words': [
          {'word': 'Hello', 'start': 0.2, 'end': 0.9},
          {'word': 'world.', 'start': 1.4, 'end': 2.0},
        ],
      });

      final result = await transcribe(requestWordTimestamps: true);

      expect(result.text, 'Hello world.');
      expect(result.segments.map((item) => item.text), ['Hello', 'world.']);
      expect(result.segments.first.start, 0.2);
      expect(result.segmentsValid, isTrue);
      expect(result.words.map((item) => item.word), ['Hello', 'world.']);
      expect(result.wordsValid, isTrue);
      expect(result.reportedCost, 0.00012);
    });

    test('纯文本响应体也按文本处理', () async {
      adapter.enqueueText('Hello world.');

      final result = await transcribe();

      expect(result.text, 'Hello world.');
      expect(result.segmentsValid, isFalse);
    });

    test('缺少用量时费用为未知而不是零', () async {
      adapter.enqueueJson({'text': 'Hello world.'});

      final result = await transcribe();

      expect(result.reportedCost, isNull);
    });

    test('文本为空按空结果失败', () async {
      adapter.enqueueJson({'text': '   '});

      await expectLater(
        transcribe(),
        throwsA(
          isA<SpeechTranscriptionException>().having(
            (error) => error.kind,
            'kind',
            SpeechTranscriptionErrorKind.emptyResult,
          ),
        ),
      );
    });

    test('正文不是对象也不是文本时按无效响应失败', () async {
      adapter.enqueueJson([1, 2, 3]);

      await expectLater(
        transcribe(),
        throwsA(
          isA<SpeechTranscriptionException>().having(
            (error) => error.kind,
            'kind',
            SpeechTranscriptionErrorKind.invalidResponse,
          ),
        ),
      );
    });
  });

  group('严格校验片段', () {
    test('越过音频范围的片段不能算作字幕可用', () async {
      adapter.enqueueJson({
        'text': 'Hello world.',
        'duration': 4.0,
        'segments': [
          {'start': 0.2, 'end': 9.5, 'text': 'Hello world.'},
        ],
      });

      final result = await transcribe();

      expect(result.segmentsValid, isFalse);
      expect(result.segments, isEmpty);
    });

    test('小于舍入容差的越界可以接受', () async {
      adapter.enqueueJson({
        'text': 'Hello world.',
        'duration': 4.0,
        'segments': [
          {'start': 0.2, 'end': 4.1, 'text': 'Hello world.'},
        ],
      });

      final result = await transcribe();

      expect(result.segmentsValid, isTrue);
    });

    test('起点晚于终点或顺序颠倒的片段被丢弃', () async {
      adapter.enqueueJson({
        'text': 'Hello world.',
        'duration': 4.0,
        'segments': [
          {'start': 2.0, 'end': 3.0, 'text': 'world.'},
          {'start': 0.2, 'end': 1.0, 'text': 'Hello'},
          {'start': 2.5, 'end': 2.0, 'text': 'inverted'},
        ],
      });

      final result = await transcribe();

      expect(result.segmentsValid, isFalse);
    });

    test('没有片段的文本模型只能证明文本可用', () async {
      adapter.enqueueJson({'text': 'Hello world.', 'duration': 4.0});

      final result = await transcribe();

      expect(result.text, 'Hello world.');
      expect(result.segmentsValid, isFalse);
    });

    test('词时间戳同样校验范围', () async {
      adapter.enqueueJson({
        'text': 'Hello world.',
        'duration': 4.0,
        'segments': [
          {'start': 0.2, 'end': 3.4, 'text': 'Hello world.'},
        ],
        'words': [
          {'word': 'Hello', 'start': 0.2, 'end': 0.9},
          {'word': 'world.', 'start': 3.0, 'end': 6.2},
        ],
      });

      final result = await transcribe(requestWordTimestamps: true);

      expect(result.segmentsValid, isTrue);
      expect(result.wordsValid, isFalse);
    });
  });

  group('错误分类', () {
    Future<void> expectKind(int status, SpeechTranscriptionErrorKind kind) async {
      adapter.enqueueJson({'error': 'failed'}, status: status);
      await expectLater(
        transcribe(),
        throwsA(
          isA<SpeechTranscriptionException>()
              .having((error) => error.kind, 'kind', kind)
              .having((error) => error.statusCode, 'statusCode', status),
        ),
      );
    }

    test('鉴权、余额、地址、限流与大小分别分类', () async {
      await expectKind(401, SpeechTranscriptionErrorKind.unauthorized);
      await expectKind(402, SpeechTranscriptionErrorKind.insufficientBalance);
      await expectKind(404, SpeechTranscriptionErrorKind.notFound);
      await expectKind(429, SpeechTranscriptionErrorKind.rateLimited);
      await expectKind(413, SpeechTranscriptionErrorKind.payloadTooLarge);
      await expectKind(500, SpeechTranscriptionErrorKind.serverError);
      await expectKind(503, SpeechTranscriptionErrorKind.serverError);
    });

    test('400 指向输出格式或时间戳参数时按能力不支持分类', () async {
      adapter.enqueueJson(
        {'error': 'response_format verbose_json is not supported'},
        status: 400,
      );

      await expectLater(
        transcribe(),
        throwsA(
          isA<SpeechTranscriptionException>().having(
            (error) => error.kind,
            'kind',
            SpeechTranscriptionErrorKind.unsupportedCapability,
          ),
        ),
      );
    });

    test('其他 400 按请求参数无效分类', () async {
      adapter.enqueueJson({'error': 'bad model id'}, status: 400);

      await expectLater(
        transcribe(),
        throwsA(
          isA<SpeechTranscriptionException>().having(
            (error) => error.kind,
            'kind',
            SpeechTranscriptionErrorKind.invalidRequest,
          ),
        ),
      );
    });

    test('5xx 不自动重试', () async {
      adapter.enqueueJson({'error': 'failed'}, status: 500);
      adapter.enqueueJson({'text': 'Hello world.'});

      await expectLater(
        transcribe(),
        throwsA(isA<SpeechTranscriptionException>()),
      );

      expect(adapter.requestCount, 1);
    });

    test('超时与取消分别分类', () async {
      adapter.enqueueError(DioExceptionType.receiveTimeout);
      await expectLater(
        transcribe(),
        throwsA(
          isA<SpeechTranscriptionException>().having(
            (error) => error.kind,
            'kind',
            SpeechTranscriptionErrorKind.timeout,
          ),
        ),
      );

      adapter.enqueueError(DioExceptionType.cancel);
      await expectLater(
        transcribe(),
        throwsA(
          isA<SpeechTranscriptionException>().having(
            (error) => error.kind,
            'kind',
            SpeechTranscriptionErrorKind.cancelled,
          ),
        ),
      );
    });
  });
}
