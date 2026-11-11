import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/services/api_log_interceptor.dart';

void main() {
  group('ApiLogInterceptor', () {
    late List<String> logs;
    late ApiLogInterceptor interceptor;

    setUp(() {
      logs = <String>[];
      interceptor = ApiLogInterceptor(tag: 'TEST', logPrint: logs.add);
    });

    /// 执行 [body] 并返回拦截器打印的全部文本。
    /// handler.next(...) 会在异步 gap 中以错误完成内部 Completer，
    /// 无监听者时表现为未捕获异步错误，用 runZonedGuarded 吞掉即可。
    String capture(void Function() body) {
      runZonedGuarded(body, (_, __) {});
      return logs.join('\n');
    }

    String captureLog(DioException err) =>
        capture(() => interceptor.onError(err, ErrorInterceptorHandler()));

    test('请求阶段：打印方法、URL 和请求体', () {
      final options = RequestOptions(
        path: '/api/v2/ai/translate',
        method: 'POST',
        baseUrl: 'https://api.test',
        data: {'text': 'hello'},
      );

      final log = capture(
        () => interceptor.onRequest(options, RequestInterceptorHandler()),
      );

      expect(log, contains('→'));
      expect(log, contains('POST'));
      expect(log, contains('/api/v2/ai/translate'));
      expect(log, contains('hello'));
    });

    test('响应阶段：打印状态码、响应体和耗时', () {
      final options = RequestOptions(
        path: '/api/v2/ai/translate',
        method: 'POST',
        baseUrl: 'https://api.test',
      );
      // 模拟 onRequest 已记录起始时间
      capture(
        () => interceptor.onRequest(options, RequestInterceptorHandler()),
      );
      final response = Response(
        requestOptions: options,
        statusCode: 200,
        data: {'translation': '你好'},
      );

      final log = capture(
        () => interceptor.onResponse(response, ResponseInterceptorHandler()),
      );

      expect(log, contains('←'));
      expect(log, contains('200'));
      expect(log, contains('你好'));
      expect(log, contains('ms)'));
    });

    test('响应阶段：有协议版本时打印实际 HTTP 版本', () {
      final options = RequestOptions(
        path: '/api/v1/stream/analyze',
        method: 'POST',
        baseUrl: 'https://api.test',
      );
      final response = Response(
        requestOptions: options,
        statusCode: 200,
        data: '(stream)',
      )..extra[HttpClientAdapter.extraKeyHttpVersion] = '2.0';

      final log = capture(
        () => interceptor.onResponse(response, ResponseInterceptorHandler()),
      );

      expect(log, contains('HTTP/2.0'));
    });

    test('带响应体的错误：打印状态码和服务器响应体', () {
      final err = DioException(
        requestOptions: RequestOptions(
          path: '/api/v2/ai/translate',
          method: 'POST',
        ),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/api/v2/ai/translate'),
          statusCode: 400,
          statusMessage: 'Bad Request',
          data: {'error': 'invalid_language', 'message': '不支持的语言'},
        ),
      );

      final log = captureLog(err);

      expect(log, contains('❌ 请求失败'));
      expect(log, contains('POST'));
      expect(log, contains('/api/v2/ai/translate'));
      expect(log, contains('400'));
      expect(log, contains('invalid_language'));
      expect(log, contains('不支持的语言'));
    });

    test('无响应的错误（超时/断网）：打印底层异常', () {
      final err = DioException(
        requestOptions: RequestOptions(path: '/api/v2/ai/analyze'),
        type: DioExceptionType.connectionTimeout,
        error: 'Connection timed out',
      );

      final log = captureLog(err);

      expect(log, contains('无响应'));
      expect(log, contains('Connection timed out'));
      expect(log, contains('connectionTimeout'));
    });

    test('取消请求：不打印任何日志', () {
      final cancelToken = CancelToken();
      cancelToken.cancel('用户取消');
      final err = DioException(
        requestOptions: RequestOptions(path: '/api/v2/ai/translate'),
        type: DioExceptionType.cancel,
        error: cancelToken.cancelError,
      );

      final log = captureLog(err);

      expect(log, isEmpty);
    });

    test('超长响应体：截断到 2000 字符', () {
      final longText = 'x' * 5000;
      final err = DioException(
        requestOptions: RequestOptions(path: '/api/v2/ai/translate'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/api/v2/ai/translate'),
          statusCode: 500,
          data: longText,
        ),
      );

      final log = captureLog(err);

      expect(log, contains('已截断'));
      expect(log, contains('共 5000 字符'));
    });

    test('请求与响应体中的凭据、用户标识和预签名 URL 会脱敏', () {
      final options = RequestOptions(
        path: '/api/test',
        method: 'POST',
        data: {
          'accessToken': 'secret-token',
          'userId': 'full-user-id',
          'nested': {'uploadUrl': 'https://signed.example/private'},
        },
      );
      final response = Response(
        requestOptions: options,
        statusCode: 200,
        data: {'app_user_id': 'another-user-id'},
      );

      final log = capture(() {
        interceptor.onRequest(options, RequestInterceptorHandler());
        interceptor.onResponse(response, ResponseInterceptorHandler());
      });

      expect(log, contains('***'));
      expect(log, isNot(contains('secret-token')));
      expect(log, isNot(contains('full-user-id')));
      expect(log, isNot(contains('signed.example')));
      expect(log, isNot(contains('another-user-id')));
    });

    test('URI query、请求体和响应体中的 OAuth 敏感字段统一脱敏', () {
      final options = RequestOptions(
        path: '/api/v1/netdisk/baidu/oauth/session/status',
        method: 'POST',
        baseUrl: 'https://api.test',
        queryParameters: {
          'code': 'oauth-code',
          'state': 'oauth-state',
          'dlink': 'https://d.pcs.baidu.com/file?secret=1',
          'safe': 'ok',
        },
        data: {
          'sessionId': 'sid-secret',
          'pollToken': 'poll-secret',
          'clientSecret': 'client-secret',
        },
      );
      final response = Response(
        requestOptions: options,
        statusCode: 200,
        data: {
          'credential': {
            'accessToken': 'access-secret',
            'refreshToken': 'refresh-secret',
          },
        },
      );

      final log = capture(() {
        interceptor.onRequest(options, RequestInterceptorHandler());
        interceptor.onResponse(response, ResponseInterceptorHandler());
      });

      expect(log, contains('safe=ok'));
      expect(log, contains('code=***'));
      expect(log, contains('state=***'));
      expect(log, contains('dlink=***'));
      expect(log, isNot(contains('oauth-code')));
      expect(log, isNot(contains('oauth-state')));
      expect(log, isNot(contains('sid-secret')));
      expect(log, isNot(contains('poll-secret')));
      expect(log, isNot(contains('client-secret')));
      expect(log, isNot(contains('access-secret')));
      expect(log, isNot(contains('refresh-secret')));
      expect(log, isNot(contains('d.pcs.baidu.com')));
    });
  });
}
