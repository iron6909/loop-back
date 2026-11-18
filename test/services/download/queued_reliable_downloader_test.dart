import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/services/background_file_download_service.dart';
import 'package:loop_back/services/download/queued_reliable_downloader.dart';
import 'package:loop_back/services/reliable_http_downloader.dart';

/// 记录入参并可选写入目标文件的假 runner。
class _FakeRunner implements BackgroundDownloadRunner {
  _FakeRunner({
    this.result = const BackgroundDownloadResult(
      status: BackgroundDownloadStatus.complete,
    ),
    this.createFile = true,
  });

  final BackgroundDownloadResult result;
  static const List<int> bytes = <int>[1, 2, 3];
  final bool createFile;

  Uri? uri;
  String? savePath;
  Map<String, String>? headers;
  int calls = 0;

  @override
  Future<BackgroundDownloadResult> enqueue({
    required Uri uri,
    required String savePath,
    String? displayName,
    required Map<String, String> headers,
    required BackgroundFileDownloadProgress? onProgress,
    required CancelToken? cancelToken,
  }) async {
    calls++;
    this.uri = uri;
    this.savePath = savePath;
    this.headers = headers;
    onProgress?.call(bytes.length, bytes.length);
    if (createFile && result.status == BackgroundDownloadStatus.complete) {
      await File(savePath).parent.create(recursive: true);
      await File(savePath).writeAsBytes(bytes);
    }
    return result;
  }
}

void main() {
  late Directory dataDir;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('queued_dl_');
  });

  tearDown(() async {
    if (dataDir.existsSync()) await dataDir.delete(recursive: true);
  });

  QueuedReliableHttpDownloader buildDownloader(_FakeRunner runner) {
    return QueuedReliableHttpDownloader(
      queue: BackgroundFileDownloadService(
        runner: runner,
        resolveDataDir: () async => dataDir,
      ),
    );
  }

  String targetPath(String name) => '${dataDir.path}/models/$name';

  test('下载成功：落到 savePath，按实际字节数返回', () async {
    final runner = _FakeRunner();
    final downloader = buildDownloader(runner);
    final savePath = targetPath('model.onnx');

    final result = await downloader.download(
      uri: Uri.parse('https://example.com/model.onnx'),
      savePath: savePath,
      expectedSize: 3,
    );

    expect(result.bytesWritten, 3);
    expect(result.savePath, savePath);
    expect(result.resumed, isFalse);
    expect(File(savePath).lengthSync(), 3);
    expect(runner.uri.toString(), 'https://example.com/model.onnx');
  });

  test('大小与 expectedSize 不符时抛 integrity（安装前必须拦住）', () async {
    final downloader = buildDownloader(_FakeRunner());

    await expectLater(
      downloader.download(
        uri: Uri.parse('https://example.com/model.onnx'),
        savePath: targetPath('model.onnx'),
        expectedSize: 999,
      ),
      throwsA(
        isA<ReliableDownloadException>().having(
          (e) => e.kind,
          'kind',
          ReliableDownloadFailure.integrity,
        ),
      ),
    );
  });

  test('404 归为 httpStatus 并带 statusCode（镜像回落据此判定）', () async {
    final downloader = buildDownloader(
      _FakeRunner(
        result: const BackgroundDownloadResult(
          status: BackgroundDownloadStatus.notFound,
          statusCode: 404,
        ),
        createFile: false,
      ),
    );

    await expectLater(
      downloader.download(
        uri: Uri.parse('https://hf-mirror.com/x.onnx'),
        savePath: targetPath('x.onnx'),
      ),
      throwsA(
        isA<ReliableDownloadException>()
            .having((e) => e.kind, 'kind', ReliableDownloadFailure.httpStatus)
            .having((e) => e.statusCode, 'statusCode', 404),
      ),
    );
  });

  test('5xx 归为 httpStatus 并保留状态码', () async {
    final downloader = buildDownloader(
      _FakeRunner(
        result: const BackgroundDownloadResult(
          status: BackgroundDownloadStatus.failed,
          statusCode: 503,
        ),
        createFile: false,
      ),
    );

    await expectLater(
      downloader.download(
        uri: Uri.parse('https://hf-mirror.com/x.onnx'),
        savePath: targetPath('x.onnx'),
      ),
      throwsA(
        isA<ReliableDownloadException>()
            .having((e) => e.kind, 'kind', ReliableDownloadFailure.httpStatus)
            .having((e) => e.statusCode, 'statusCode', 503),
      ),
    );
  });

  test('取消归为 cancelled，存储失败归为 storage', () async {
    final cancelled = buildDownloader(
      _FakeRunner(
        result: const BackgroundDownloadResult(
          status: BackgroundDownloadStatus.canceled,
        ),
        createFile: false,
      ),
    );
    await expectLater(
      cancelled.download(
        uri: Uri.parse('https://example.com/a'),
        savePath: targetPath('a'),
      ),
      throwsA(
        isA<ReliableDownloadException>().having(
          (e) => e.kind,
          'kind',
          ReliableDownloadFailure.cancelled,
        ),
      ),
    );

    final storage = buildDownloader(
      _FakeRunner(
        result: const BackgroundDownloadResult(
          status: BackgroundDownloadStatus.failed,
          isStorageFailure: true,
        ),
        createFile: false,
      ),
    );
    await expectLater(
      storage.download(
        uri: Uri.parse('https://example.com/b'),
        savePath: targetPath('b'),
      ),
      throwsA(
        isA<ReliableDownloadException>().having(
          (e) => e.kind,
          'kind',
          ReliableDownloadFailure.storage,
        ),
      ),
    );
  });

  test('调用前已取消则不提交任务', () async {
    final runner = _FakeRunner();
    final token = CancelToken()..cancel('user');
    final downloader = buildDownloader(runner);

    await expectLater(
      downloader.download(
        uri: Uri.parse('https://example.com/a'),
        savePath: targetPath('a'),
        cancelToken: token,
      ),
      throwsA(
        isA<ReliableDownloadException>().having(
          (e) => e.kind,
          'kind',
          ReliableDownloadFailure.cancelled,
        ),
      ),
    );
    expect(runner.calls, 0);
  });
}
