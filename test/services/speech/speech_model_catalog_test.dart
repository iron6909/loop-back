/// OpenRouter 转写模型目录测试。
///
/// 目录只证明模型存在：这里只验证真实请求形状与失败分类，不把它当作能力结论。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/services/speech/speech_config.dart';
import 'package:echo_loop/services/speech/speech_model_catalog.dart';
import 'package:echo_loop/services/speech/speech_transcription_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<Object> _responses = [];

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
    _responses.add(ResponseBody.fromString(body, status));
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (_responses.isEmpty) throw StateError('没有预设响应');
    return _responses.removeAt(0) as ResponseBody;
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _FakeAdapter adapter;
  late SpeechModelCatalogClient client;

  const openRouterConfig = SpeechConfig(
    kind: SpeechProviderKind.openrouter,
    baseUrl: 'https://openrouter.ai/api/v1',
  );

  setUp(() {
    adapter = _FakeAdapter();
    client = SpeechModelCatalogClient(
      dio: Dio()..httpClientAdapter = adapter,
    );
  });

  test('只查询专用 STT 目录并带上语音 Key', () async {
    adapter.enqueueJson({
      'data': [
        {'id': 'openai/whisper-large-v3'},
        {'id': 'openai/gpt-4o-transcribe'},
      ],
    });

    final models = await client.fetchTranscriptionModels(
      config: openRouterConfig,
      apiKey: 'sk-speech-test',
    );

    final request = adapter.requests.single;
    expect(request.method, 'GET');
    expect(
      request.uri.toString(),
      'https://openrouter.ai/api/v1/models?output_modalities=transcription',
    );
    expect(request.headers['Authorization'], 'Bearer sk-speech-test');
    expect(models, ['openai/whisper-large-v3', 'openai/gpt-4o-transcribe']);
  });

  test('目录为空时返回空列表，仍然可以手填模型', () async {
    adapter.enqueueJson({'data': []});

    final models = await client.fetchTranscriptionModels(
      config: openRouterConfig,
      apiKey: 'sk-speech-test',
    );

    expect(models, isEmpty);
  });

  test('自定义服务不查询目录，也不发送凭据', () async {
    const custom = SpeechConfig(
      kind: SpeechProviderKind.custom,
      baseUrl: 'https://speech.example.com/v1',
    );

    await expectLater(
      client.fetchTranscriptionModels(
        config: custom,
        apiKey: 'sk-speech-test',
      ),
      throwsA(isA<ArgumentError>()),
    );

    expect(adapter.requests, isEmpty);
  });

  test('鉴权失败按可分类错误抛出，不影响手填', () async {
    adapter.enqueueJson({'error': 'unauthorized'}, status: 401);

    await expectLater(
      client.fetchTranscriptionModels(
        config: openRouterConfig,
        apiKey: 'sk-speech-test',
      ),
      throwsA(
        isA<SpeechTranscriptionException>().having(
          (error) => error.kind,
          'kind',
          SpeechTranscriptionErrorKind.unauthorized,
        ),
      ),
    );
  });

  test('非目录正文按无效响应处理', () async {
    adapter.enqueueText('<html>gateway</html>');

    await expectLater(
      client.fetchTranscriptionModels(
        config: openRouterConfig,
        apiKey: 'sk-speech-test',
      ),
      throwsA(
        isA<SpeechTranscriptionException>().having(
          (error) => error.kind,
          'kind',
          SpeechTranscriptionErrorKind.invalidResponse,
        ),
      ),
    );
  });
}
