/// 用量查询服务测试
///
/// 用假 adapter 控制响应与时机，验证缓存、并发合并、失败保留与配置切换作废。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/services/provider/provider_config.dart';
import 'package:echo_loop/services/provider/provider_http_client.dart';
import 'package:echo_loop/services/provider/usage_models.dart';
import 'package:echo_loop/services/provider/usage_query_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按队列返回预设响应的 adapter，支持用闸门控制完成时机。
class _FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<Future<ResponseBody> Function()> _queue = [];

  void enqueueJson(Object payload, {int status = 200}) {
    _queue.add(
      () async => ResponseBody.fromString(
        jsonEncode(payload),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
  }

  /// 排队一个要等 [gate] 完成才返回的响应，用于观察在途状态。
  void enqueueGated(Completer<void> gate, Object payload) {
    _queue.add(() async {
      await gate.future;
      return ResponseBody.fromString(
        jsonEncode(payload),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (_queue.isEmpty) throw StateError('没有预设响应');
    return _queue.removeAt(0)();
  }

  @override
  void close({bool force = false}) {}
}

/// DeepSeek 余额样例（金额为字符串）。
Map<String, Object?> _deepSeekBody({String total = '110.00'}) => {
  'is_available': true,
  'balance_infos': [
    {
      'currency': 'CNY',
      'total_balance': total,
      'granted_balance': '10.00',
      'topped_up_balance': '100.00',
    },
  ],
};

void main() {
  late _FakeAdapter adapter;
  late Dio dio;
  late DateTime clock;

  setUp(() {
    adapter = _FakeAdapter();
    dio = Dio()..httpClientAdapter = adapter;
    clock = DateTime(2026, 11, 1, 11, 20);
  });

  UsageQueryService service({
    ProviderKind kind = ProviderKind.deepseek,
    String baseUrl = 'https://api.deepseek.com',
  }) => UsageQueryService(
    http: ProviderHttpClient(
      config: ProviderConfig(kind: kind, baseUrl: baseUrl, model: 'm'),
      apiKey: 'fixture-key',
      dio: dio,
    ),
    config: ProviderConfig(kind: kind, baseUrl: baseUrl, model: 'm'),
    now: () => clock,
  );

  group('端点选择', () {
    test('DeepSeek 查账户余额端点', () async {
      adapter.enqueueJson(_deepSeekBody());
      await service().refresh();

      expect(
        adapter.requests.single.uri.toString(),
        'https://api.deepseek.com/user/balance',
      );
    });

    test('OpenRouter 查账户余额端点', () async {
      adapter.enqueueJson({
        'data': {'total_credits': 20, 'total_usage': 5},
      });
      final view = await service(
        kind: ProviderKind.openrouter,
        baseUrl: 'https://openrouter.ai/api/v1',
      ).refresh();

      expect(
        adapter.requests.single.uri.toString(),
        'https://openrouter.ai/api/v1/credits',
      );
      expect(view.snapshot?.amounts.single.total, 15);
    });

    test('OpenCode Go 主机查三窗口端点', () async {
      adapter.enqueueJson({
        'usage': {
          'rolling': {'percent': 40},
          'weekly': {'percent': 10},
          'monthly': {'percent': 5},
        },
      });
      final view = await service(
        kind: ProviderKind.custom,
        baseUrl: 'https://opencode.ai/inference/go/openai/v1',
      ).refresh();

      expect(
        adapter.requests.single.uri.toString(),
        'https://opencode.ai/zen/go/v1/usage',
      );
      expect(view.snapshot?.windows, hasLength(3));
    });

    test('自定义未知主机返回不支持，且不发任何请求', () async {
      final view = await service(
        kind: ProviderKind.custom,
        baseUrl: 'https://my-gateway.example/v1',
      ).refresh();

      expect(view.unsupported, isTrue);
      expect(view.hasData, isFalse);
      expect(adapter.requests, isEmpty);
    });
  });

  group('缓存与并发', () {
    test('60 秒内重复刷新复用上次结果', () async {
      adapter.enqueueJson(_deepSeekBody());
      final subject = service();
      await subject.refresh();

      clock = clock.add(const Duration(seconds: 59));
      await subject.refresh();

      expect(adapter.requests, hasLength(1));
    });

    test('超过 60 秒重新请求', () async {
      adapter.enqueueJson(_deepSeekBody());
      adapter.enqueueJson(_deepSeekBody(total: '99.00'));
      final subject = service();
      await subject.refresh();

      clock = clock.add(const Duration(seconds: 61));
      final view = await subject.refresh();

      expect(adapter.requests, hasLength(2));
      expect(view.snapshot?.amounts.single.total, 99);
    });

    test('force 跳过缓存立即刷新', () async {
      adapter.enqueueJson(_deepSeekBody());
      adapter.enqueueJson(_deepSeekBody(total: '88.00'));
      final subject = service();
      await subject.refresh();
      final view = await subject.refresh(force: true);

      expect(adapter.requests, hasLength(2));
      expect(view.snapshot?.amounts.single.total, 88);
    });

    test('并发刷新合并为一次请求', () async {
      final gate = Completer<void>();
      adapter.enqueueGated(gate, _deepSeekBody());
      final subject = service();

      final first = subject.refresh();
      final second = subject.refresh();
      gate.complete();
      await Future.wait([first, second]);

      expect(adapter.requests, hasLength(1));
    });
  });

  group('失败与切换', () {
    test('失败保留上次成功值与时间', () async {
      adapter.enqueueJson(_deepSeekBody());
      adapter.enqueueJson({'unexpected': true}, status: 500);
      final subject = service();
      await subject.refresh();
      final before = subject.current.fetchedAt;

      clock = clock.add(const Duration(seconds: 61));
      final view = await subject.refresh();

      expect(view.failed, isTrue);
      expect(view.snapshot?.amounts.single.total, 110);
      expect(view.fetchedAt, before);
    });

    test('从未成功时没有数据', () async {
      adapter.enqueueJson({'unexpected': true}, status: 500);
      final view = await service().refresh();

      expect(view.hasData, isFalse);
      expect(view.failed, isTrue);
    });

    test('形状不认识也算失败，不写半成品', () async {
      adapter.enqueueJson({'balance_infos': 'not-a-list'});
      final view = await service().refresh();

      expect(view.hasData, isFalse);
      expect(view.failed, isTrue);
    });

    test('OpenRouter 账户余额无权限时回退 Key 预算', () async {
      adapter.enqueueJson({'error': 'forbidden'}, status: 403);
      adapter.enqueueJson({
        'data': {'limit_remaining': null, 'limit_reset': 'monthly'},
      });
      final view = await service(
        kind: ProviderKind.openrouter,
        baseUrl: 'https://openrouter.ai/api/v1',
      ).refresh();

      expect(adapter.requests, hasLength(2));
      expect(
        adapter.requests.last.uri.toString(),
        'https://openrouter.ai/api/v1/key',
      );
      expect(view.snapshot?.scope, UsageScope.keyBudget);
      expect(view.snapshot?.budgetNotSet, isTrue);
      expect(view.snapshot?.amounts, isEmpty);
    });

    test('invalidate 后在途结果不写回', () async {
      final gate = Completer<void>();
      adapter.enqueueGated(gate, _deepSeekBody());
      final subject = service();

      final pending = subject.refresh();
      subject.invalidate();
      gate.complete();
      await pending;

      expect(subject.current.hasData, isFalse);
    });
  });
}
