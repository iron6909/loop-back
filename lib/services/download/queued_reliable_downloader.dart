import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../background_file_download_service.dart';
import '../reliable_http_downloader.dart';

/// 把可靠下载的 GET 交给全局后台下载队列。
///
/// 调用方仍按 [ReliableHttpDownloader] 使用：大小校验、sha256 与安装留在调用方；
/// 真正的传输交给系统下载插件，因此模型下载与用户文件下载共享同一套能力：
/// 全局并发 2、失败重试、断点续传、系统通知，以及 App 退到后台后仍继续。
///
/// 与 [DioReliableHttpDownloader] 的差异：
/// - `savePath` 必须在应用数据目录内（队列按应用支持目录解析相对路径），模型
///   缓存的落盘位置本就满足；
/// - 去重键是 `savePath`（[identityKey] 不参与），同一目标文件的重复调用会并入
///   同一条队列任务；
/// - 续传由插件按任务管理，[ReliableDownloadResult.resumed] 恒为 false（调用方
///   目前只用它记日志）；
/// - 失败按插件终态归类：带 `statusCode` 的归为 [ReliableDownloadFailure.httpStatus]，
///   镜像回落（`source_fallback`）仍能据此判定 404/410 与 5xx。
class QueuedReliableHttpDownloader implements ReliableHttpDownloader {
  QueuedReliableHttpDownloader({required BackgroundFileDownloadService queue})
    : _queue = queue;

  final BackgroundFileDownloadService _queue;

  @override
  Future<ReliableDownloadResult> download({
    required Uri uri,
    required String savePath,
    Map<String, String> headers = const <String, String>{},
    int? expectedSize,
    String? identityKey,
    bool allowResume = true,
    CancelToken? cancelToken,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      throw ReliableDownloadException(
        'Download canceled before start.',
        kind: ReliableDownloadFailure.cancelled,
      );
    }

    try {
      await _queue.download(
        uri: uri,
        savePath: savePath,
        displayName: p.basename(savePath),
        headers: headers,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
    } on BackgroundFileDownloadException catch (error) {
      throw _mapFailure(error);
    }

    final written = await _fileLength(savePath);
    if (expectedSize != null && written != expectedSize) {
      throw ReliableDownloadException(
        'Downloaded size mismatch: expected $expectedSize, got $written.',
        kind: ReliableDownloadFailure.integrity,
      );
    }
    return ReliableDownloadResult(
      savePath: savePath,
      bytesWritten: written,
      resumed: false,
    );
  }

  /// 把队列的失败语义映射回可靠下载器的失败语义。
  ReliableDownloadException _mapFailure(BackgroundFileDownloadException error) {
    if (error.isCanceled) {
      return ReliableDownloadException(
        error.message,
        kind: ReliableDownloadFailure.cancelled,
        cause: error.cause,
      );
    }
    if (error.isStorageFailure) {
      return ReliableDownloadException(
        error.message,
        kind: ReliableDownloadFailure.storage,
        cause: error.cause,
      );
    }
    final statusCode = error.statusCode;
    if (statusCode != null) {
      return ReliableDownloadException(
        error.message,
        kind: ReliableDownloadFailure.httpStatus,
        statusCode: statusCode,
        cause: error.cause,
      );
    }
    return ReliableDownloadException(
      error.message,
      kind: ReliableDownloadFailure.network,
      cause: error.cause,
    );
  }

  Future<int> _fileLength(String savePath) async {
    try {
      return await File(savePath).length();
    } on FileSystemException catch (error) {
      throw ReliableDownloadException(
        'Download finished but the file is unreadable: ${error.message}',
        kind: ReliableDownloadFailure.storage,
        cause: error,
      );
    }
  }
}
