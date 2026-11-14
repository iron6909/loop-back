import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/services/asr/asr_model_catalog.dart'
    show AsrDownloadSource;
import 'package:loop_back/services/download/source_fallback.dart';
import 'package:loop_back/services/reliable_http_downloader.dart';

ReliableDownloadException _httpError(int status) => ReliableDownloadException(
  'status $status',
  kind: ReliableDownloadFailure.httpStatus,
  statusCode: status,
);

void main() {
  group('shouldFallBackToUpstream', () {
    test('资源不存在：404 / 410 回落', () {
      expect(shouldFallBackToUpstream(_httpError(404)), isTrue);
      expect(shouldFallBackToUpstream(_httpError(410)), isTrue);
    });

    test('镜像服务端错误：5xx 回落', () {
      expect(shouldFallBackToUpstream(_httpError(500)), isTrue);
      expect(shouldFallBackToUpstream(_httpError(503)), isTrue);
    });

    test('客户端错误（鉴权/限流/请求非法）不回落', () {
      expect(shouldFallBackToUpstream(_httpError(400)), isFalse);
      expect(shouldFallBackToUpstream(_httpError(401)), isFalse);
      expect(shouldFallBackToUpstream(_httpError(403)), isFalse);
      expect(shouldFallBackToUpstream(_httpError(429)), isFalse);
    });

    test('网络波动类失败不回落（中国区切上游只会更差）', () {
      for (final kind in [
        ReliableDownloadFailure.timeout,
        ReliableDownloadFailure.network,
        ReliableDownloadFailure.redirect,
        ReliableDownloadFailure.cancelled,
        ReliableDownloadFailure.integrity,
        ReliableDownloadFailure.unknown,
      ]) {
        expect(
          shouldFallBackToUpstream(
            ReliableDownloadException('x', kind: kind, statusCode: 404),
          ),
          isFalse,
          reason: '$kind 不应回落',
        );
      }
    });
  });

  group('withUpstreamFallback', () {
    test('上游直连：只跑一次，异常原样抛出', () async {
      var calls = 0;
      await expectLater(
        withUpstreamFallback<void>(
          logTag: 'Test',
          source: AsrDownloadSource.huggingFace,
          run: (source) async {
            calls++;
            expect(source, AsrDownloadSource.huggingFace);
            throw _httpError(404);
          },
        ),
        throwsA(isA<ReliableDownloadException>()),
      );
      expect(calls, 1);
    });

    test('镜像 404：用上游再跑一次并返回成功结果', () async {
      final sources = <AsrDownloadSource>[];
      final result = await withUpstreamFallback<String>(
        logTag: 'Test',
        source: AsrDownloadSource.huggingFaceMirror,
        run: (source) async {
          sources.add(source);
          if (source == AsrDownloadSource.huggingFaceMirror) {
            throw _httpError(404);
          }
          return 'ok';
        },
      );
      expect(result, 'ok');
      expect(sources, [
        AsrDownloadSource.huggingFaceMirror,
        AsrDownloadSource.huggingFace,
      ]);
    });

    test('镜像网络超时：不回落，异常原样抛出', () async {
      final sources = <AsrDownloadSource>[];
      await expectLater(
        withUpstreamFallback<void>(
          logTag: 'Test',
          source: AsrDownloadSource.huggingFaceMirror,
          run: (source) async {
            sources.add(source);
            throw const ReliableDownloadException(
              'timeout',
              kind: ReliableDownloadFailure.timeout,
            );
          },
        ),
        throwsA(isA<ReliableDownloadException>()),
      );
      expect(sources, [AsrDownloadSource.huggingFaceMirror]);
    });

    test('镜像成功：不触发上游', () async {
      final sources = <AsrDownloadSource>[];
      await withUpstreamFallback<void>(
        logTag: 'Test',
        source: AsrDownloadSource.huggingFaceMirror,
        run: (source) async => sources.add(source),
      );
      expect(sources, [AsrDownloadSource.huggingFaceMirror]);
    });
  });
}
