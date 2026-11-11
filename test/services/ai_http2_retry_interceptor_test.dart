import 'package:dio/dio.dart';
import 'package:loop_back/services/ai_http2_retry_interceptor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockAdapter extends Mock implements HttpClientAdapter {}

void main() {
  setUpAll(() {
    registerFallbackValue(RequestOptions(path: '/'));
  });

  late MockAdapter adapter;
  late Dio dio;

  ResponseBody okBody() => ResponseBody.fromString('ok', 200);

  DioException connErr(RequestOptions o) =>
      DioException.connectionError(requestOptions: o, reason: 'stale h2');

  /// 令 adapter.fetch 第 N 次调用按 [outcomes] 决定成功/抛错（越界则成功）。
  void stubFetch(List<DioException?> outcomes) {
    var calls = 0;
    when(() => adapter.fetch(any(), any(), any())).thenAnswer((inv) async {
      final o = inv.positionalArguments[0] as RequestOptions;
      final i = calls++;
      final err = i < outcomes.length ? outcomes[i] : null;
      if (err != null) {
        throw err.copyWith(requestOptions: o);
      }
      return okBody();
    });
  }

  setUp(() {
    adapter = MockAdapter();
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
    dio.httpClientAdapter = adapter;
    dio.interceptors.add(AiHttp2RetryInterceptor(dio));
  });

  Options plain() => Options(responseType: ResponseType.plain);

  test('connectionError 首败次成：重试 1 次并返回成功', () async {
    stubFetch([connErr(RequestOptions(path: '/x'))]); // 第 1 次失败，第 2 次成功

    final res = await dio.get<String>('/x', options: plain());

    expect(res.statusCode, 200);
    expect(res.data, 'ok');
    verify(() => adapter.fetch(any(), any(), any())).called(2);
  });

  test('connectionError 连续失败：达上限后原错误上抛（默认 maxRetries=1）', () async {
    stubFetch([
      connErr(RequestOptions(path: '/x')),
      connErr(RequestOptions(path: '/x')),
      connErr(RequestOptions(path: '/x')),
    ]);

    await expectLater(
      dio.get<String>('/x', options: plain()),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.connectionError,
        ),
      ),
    );
    // 原始 1 次 + 重试 1 次 = 2 次，不再继续。
    verify(() => adapter.fetch(any(), any(), any())).called(2);
  });

  test('badResponse 不重试', () async {
    stubFetch([
      DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.badResponse,
      ),
    ]);

    await expectLater(
      dio.get<String>('/x', options: plain()),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.badResponse,
        ),
      ),
    );
    verify(() => adapter.fetch(any(), any(), any())).called(1);
  });

  test('cancel 类型不重试', () async {
    stubFetch([
      DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.cancel,
      ),
    ]);

    await expectLater(
      dio.get<String>('/x', options: plain()),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    verify(() => adapter.fetch(any(), any(), any())).called(1);
  });

  test('token 已取消时不重试 connectionError', () async {
    final token = CancelToken();
    when(() => adapter.fetch(any(), any(), any())).thenAnswer((inv) async {
      final o = inv.positionalArguments[0] as RequestOptions;
      token.cancel(); // 瞬断发生时用户已取消
      throw connErr(o);
    });

    await expectLater(
      dio.get<String>('/x', options: plain(), cancelToken: token),
      throwsA(isA<DioException>()),
    );
    // 已取消 → 不重试，仅 1 次。
    verify(() => adapter.fetch(any(), any(), any())).called(1);
  });

  test('connectionTimeout 同样触发重试', () async {
    stubFetch([
      DioException.connectionTimeout(
        timeout: const Duration(seconds: 15),
        requestOptions: RequestOptions(path: '/x'),
      ),
    ]);

    final res = await dio.get<String>('/x', options: plain());

    expect(res.statusCode, 200);
    verify(() => adapter.fetch(any(), any(), any())).called(2);
  });
}
