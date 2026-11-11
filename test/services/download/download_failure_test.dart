import 'dart:io' show FileSystemException, OSError;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/services/download/download_failure.dart';
import 'package:loop_back/services/reliable_http_downloader.dart';

void main() {
  group('classifyDownloadFailure', () {
    test('FileSystemException errno 28 → insufficientStorage', () {
      final e = const FileSystemException(
        'writeFrom failed',
        '/tmp/temp.tar',
        OSError('No space left on device', 28),
      );
      expect(
        classifyDownloadFailure(e),
        DownloadFailureKind.insufficientStorage,
      );
    });

    test('异常文案含 errno = 28 → insufficientStorage（无 OSError 也兜住）', () {
      expect(
        classifyDownloadFailure(Exception('OS Error: ... errno = 28')),
        DownloadFailureKind.insufficientStorage,
      );
    });

    test('DioException（非取消）→ network', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionTimeout,
      );
      expect(classifyDownloadFailure(e), DownloadFailureKind.network);
    });

    test('SHA 不匹配 → verification', () {
      expect(
        classifyDownloadFailure(StateError('archive SHA-256 mismatch')),
        DownloadFailureKind.verification,
      );
    });

    test('解包后关键文件缺失 → verification', () {
      expect(
        classifyDownloadFailure(StateError('key files missing after extract')),
        DownloadFailureKind.verification,
      );
    });

    test('其它异常 → unknown', () {
      expect(
        classifyDownloadFailure(StateError('something else')),
        DownloadFailureKind.unknown,
      );
    });

    test('ReliableDownloadException(storage) → insufficientStorage', () {
      const e = ReliableDownloadException(
        'disk full',
        kind: ReliableDownloadFailure.storage,
      );
      expect(
        classifyDownloadFailure(e),
        DownloadFailureKind.insufficientStorage,
      );
    });

    test('ReliableDownloadException(integrity) → verification', () {
      const e = ReliableDownloadException(
        'size mismatch',
        kind: ReliableDownloadFailure.integrity,
      );
      expect(classifyDownloadFailure(e), DownloadFailureKind.verification);
    });

    test('ReliableDownloadException(network/httpStatus) → network', () {
      const network = ReliableDownloadException(
        'connection failed',
        kind: ReliableDownloadFailure.network,
      );
      const httpStatus = ReliableDownloadException(
        'bad status',
        kind: ReliableDownloadFailure.httpStatus,
        statusCode: 500,
      );
      expect(classifyDownloadFailure(network), DownloadFailureKind.network);
      expect(classifyDownloadFailure(httpStatus), DownloadFailureKind.network);
    });

    test('ReliableDownloadException 的 cause 是 errno 28 时递归识别为存储不足', () {
      final e = ReliableDownloadException(
        'write failed',
        kind: ReliableDownloadFailure.storage,
        cause: const FileSystemException(
          'writeFrom failed',
          '/tmp/temp.part',
          OSError('No space left on device', 28),
        ),
      );
      // kind 本身已是 storage，无需依赖 cause 递归也能得到同样结果，
      // 这里额外验证 kind 更笼统（unknown）时仍能从 cause 兜底识别。
      final wrapped = ReliableDownloadException('write failed', cause: e);
      expect(
        classifyDownloadFailure(wrapped),
        DownloadFailureKind.insufficientStorage,
      );
    });

    test('ReliableDownloadException(cancelled) → unknown（取消不是失败，调用方应单独处理）', () {
      const e = ReliableDownloadException(
        'cancelled',
        kind: ReliableDownloadFailure.cancelled,
      );
      expect(classifyDownloadFailure(e), DownloadFailureKind.unknown);
    });
  });
}
