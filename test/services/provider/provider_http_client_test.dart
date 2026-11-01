/// 供应商 HTTP 客户端测试
///
/// 用假 adapter 而不是 mock Dio：只有真实 Dio 实例才能验证超时、基址拼接与最终
/// 请求头，避免「断言了自己设置的字段」这种自证式测试。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/services/provider/provider_config.dart';
import 'package:echo_loop/services/provider/provider_http_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录请求并按队列返回预设响应的 adapter。
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

  void enqueueError(DioExceptionType type) {
    _responses.add(
      DioException(requestOptions: RequestOptions(path: ''), type: type),
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (_responses.isEmpty) {
      throw StateError('没有预设响应');
    }
    final next = _responses.removeAt(0);
    if (next is DioException) {
      throw DioException(
        requestOptions: options,
        type: next.type,
        message: next.message,
      );
    }
    return next as ResponseBody;
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _FakeAdapter adapter;
  late Dio dio;

  setUp(() {
    adapter = _FakeAdapter();
    dio = Dio()..httpClientAdapter = adapter;
  });

  ProviderHttpClient client({
    String baseUrl = 'https://api.deepseek.com',
    ProviderKind kind = ProviderKind.deepseek,
    String model = 'deepseek-flash',
  }) => ProviderHttpClient(
    config: ProviderConfig(kind: kind, baseUrl: baseUrl, model: model),
    apiKey: 'sk-test-key',
    dio: dio,
    appVersion: '1.0.44',
  );

  group('请求构造', () {
    test('基址直接追加 /chat/completions，不自动补 /v1', () async {
      adapter.enqueueJson({'choices': <Object?>[]});
      await client().postChatCompletions({'model': 'm'});

      expect(
        adapter.requests.single.uri.toString(),
        'https://api.deepseek.com/chat/completions',
      );
    });

    test('保留用户填写的子路径', () async {
      adapter.enqueueJson({'choices': <Object?>[]});
      await client(baseUrl: 'https://openrouter.ai/api/v1').postChatCompletions(
        {'model': 'm'},
      );

      expect(
        adapter.requests.single.uri.toString(),
        'https://openrouter.ai/api/v1/chat/completions',
      );
    });

    test('基址尾部斜杠不会产生双斜杠', () async {
      adapter.enqueueJson({'choices': <Object?>[]});
      await client(baseUrl: 'https://api.deepseek.com/').postChatCompletions({
        'model': 'm',
      });

      expect(
        adapter.requests.single.uri.toString(),
        'https://api.deepseek.com/chat/completions',
      );
    });

    test('连接 15 秒、接收 120 秒', () async {
      adapter.enqueueJson({'choices': <Object?>[]});
      await client().postChatCompletions({'model': 'm'});

      expect(dio.options.connectTimeout, const Duration(seconds: 15));
      expect(dio.options.receiveTimeout, const Duration(seconds: 120));
    });

    test('只带 Bearer 与本应用标识，不带平台或渠道头', () async {
      adapter.enqueueJson({'choices': <Object?>[]});
      await client().postChatCompletions({'model': 'm'});

      final headers = adapter.requests.single.headers;
      expect(headers['Authorization'], 'Bearer sk-test-key');
      expect('${headers['User-Agent']}', contains('EchoLoop'));
      expect(headers.keys.where((k) => k.toLowerCase().startsWith('x-')), isEmpty);
    });

    test('请求体原样透传', () async {
      adapter.enqueueJson({'choices': <Object?>[]});
      await client().postChatCompletions({
        'model': 'deepseek-flash',
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
        'response_format': {'type': 'json_object'},
      });

      final body = adapter.requests.single.data as Map<String, Object?>;
      expect(body['model'], 'deepseek-flash');
      expect(body['response_format'], {'type': 'json_object'});
    });
  });

  group('OpenCode Go 会话头', () {
    test('opencode.ai 主机附带稳定会话标识', () async {
      adapter.enqueueJson({'choices': <Object?>[]});
      adapter.enqueueJson({'choices': <Object?>[]});
      final go = client(
        baseUrl: 'https://opencode.ai/inference/go/openai/v1',
        kind: ProviderKind.custom,
        model: 'deepseek-v4.1-flash',
      );

      await go.postChatCompletions({'model': 'm'});
      await go.postChatCompletions({'model': 'm'});

      final first = adapter.requests[0].headers['x-opencode-session'];
      final second = adapter.requests[1].headers['x-opencode-session'];
      expect(first, isA<String>());
      expect('$first', isNotEmpty);
      expect(first, second);
    });

    test('其他主机不附带会话标识', () async {
      adapter.enqueueJson({'choices': <Object?>[]});
      await client().postChatCompletions({'model': 'm'});

      expect(adapter.requests.single.headers['x-opencode-session'], isNull);
    });
  });

  group('错误分类', () {
    Future<ProviderErrorKind> kindFor(int status) async {
      adapter.enqueueJson({'error': 'x'}, status: status);
      try {
        await client().postChatCompletions({'model': 'm'});
      } on ProviderHttpException catch (error) {
        return error.kind;
      }
      fail('应当抛出 ProviderHttpException');
    }

    test('401 归为鉴权失败', () async {
      expect(await kindFor(401), ProviderErrorKind.unauthorized);
    });

    test('402 归为供应商余额不足', () async {
      expect(await kindFor(402), ProviderErrorKind.insufficientBalance);
    });

    test('404 归为地址或模型不存在', () async {
      expect(await kindFor(404), ProviderErrorKind.notFound);
    });

    test('429 归为限流', () async {
      expect(await kindFor(429), ProviderErrorKind.rateLimited);
    });

    test('超时单独分类', () async {
      adapter.enqueueError(DioExceptionType.receiveTimeout);
      await expectLater(
        client().postChatCompletions({'model': 'm'}),
        throwsA(
          isA<ProviderHttpException>().having(
            (e) => e.kind,
            'kind',
            ProviderErrorKind.timeout,
          ),
        ),
      );
    });

    test('网络异常归为网络错误', () async {
      adapter.enqueueError(DioExceptionType.connectionError);
      await expectLater(
        client().postChatCompletions({'model': 'm'}),
        throwsA(
          isA<ProviderHttpException>().having(
            (e) => e.kind,
            'kind',
            ProviderErrorKind.network,
          ),
        ),
      );
    });

    test('4xx 不重试', () async {
      adapter.enqueueJson({'error': 'x'}, status: 400);
      await expectLater(
        client().postChatCompletions({'model': 'm'}),
        throwsA(isA<ProviderHttpException>()),
      );
      expect(adapter.requests.length, 1);
    });
  });

  group('5xx 重试一次', () {
    test('首次 500 后成功则返回结果', () async {
      adapter.enqueueJson({'error': 'x'}, status: 500);
      adapter.enqueueJson({
        'choices': [
          {'message': {'content': '{}'}},
        ],
      });

      final result = await client().postChatCompletions({'model': 'm'});

      expect(adapter.requests.length, 2);
      expect(result['choices'], isA<List<Object?>>());
    });

    test('两次 500 后判服务端失败，只重试一次', () async {
      adapter.enqueueJson({'error': 'x'}, status: 500);
      adapter.enqueueJson({'error': 'x'}, status: 503);

      await expectLater(
        client().postChatCompletions({'model': 'm'}),
        throwsA(
          isA<ProviderHttpException>().having(
            (e) => e.kind,
            'kind',
            ProviderErrorKind.serverError,
          ),
        ),
      );
      expect(adapter.requests.length, 2);
    });
  });

  group('响应解析', () {
    test('非 JSON 对象响应判无效响应', () async {
      adapter.enqueueJson(<Object?>[]);
      await expectLater(
        client().postChatCompletions({'model': 'm'}),
        throwsA(
          isA<ProviderHttpException>().having(
            (e) => e.kind,
            'kind',
            ProviderErrorKind.invalidResponse,
          ),
        ),
      );
    });
  });
}
