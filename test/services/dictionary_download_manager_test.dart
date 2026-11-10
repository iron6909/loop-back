import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_loop/services/app_logger.dart';
import 'package:echo_loop/services/asr/asr_model_catalog.dart';
import 'package:echo_loop/services/dictionary/dictionary_catalog.dart';
import 'package:echo_loop/services/dictionary_download_manager.dart';
import 'package:echo_loop/services/reliable_http_downloader.dart';
import 'package:echo_loop/services/resource_install_manifest.dart';

/// 按固定下载 URL 返回预置 ZIP；其余请求 404。
class _MockAdapter implements HttpClientAdapter {
  _MockAdapter({
    required this.downloadUrl,
    this.payload,
    this.downloadStatusCode = 200,
    this.requestUris,
  });

  final String downloadUrl;
  final List<int>? payload;
  final int downloadStatusCode;
  final List<Uri>? requestUris;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestUris?.add(options.uri);
    if (options.path == downloadUrl || options.uri.toString() == downloadUrl) {
      if (downloadStatusCode != 200 || payload == null) {
        return ResponseBody(
          const Stream.empty(),
          downloadStatusCode,
          headers: {},
        );
      }
      return ResponseBody(
        Stream.fromIterable([Uint8List.fromList(payload!)]),
        200,
        headers: {
          'content-length': [payload!.length.toString()],
        },
      );
    }
    return ResponseBody(const Stream.empty(), 404, headers: {});
  }

  @override
  void close({bool force = false}) {}
}

/// 按公开源布局构造受控归档的完整下载 URL。
Uri _publicUri(String archiveFileName, AsrDownloadSource source) =>
    DictionarySpec(
      nativeLanguage: 'zh',
      resourceId: 'dict-en_zh-v1',
      archiveFileName: archiveFileName,
      archiveSha256: 'unused',
      estimatedDownloadBytes: 0,
    ).fileUri(source);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('catalog 固定两种语言的公开源资源身份', () {
    final zhCn = dictionarySpecOf('zh-CN');
    final zhTw = dictionarySpecOf('zh-TW');

    expect(zhCn.archiveFileName, 'dict_en_zh-CN-v1.sqlite.zip');
    expect(
      zhCn.archiveSha256,
      '2acfc22aae4658b707973c508e1356d4c8ce4bc07c502c6d2c3030a95bc5f5e9',
    );
    expect(zhTw.resourceId, 'dict-en_zh-TW-v1');
    expect(zhTw.archiveFileName, 'dict_en_zh-TW-v1.sqlite.zip');
    expect(zhCn.estimatedDownloadBytes, 12552930);
    expect(zhTw.estimatedDownloadBytes, 12552893);
    expect(dictionaryPublicRepository, 'banko3/loop-back');
    expect(
      dictionaryPublicRevision,
      '3b3a5bef53a1c2c86f72117a8ce149554122baac',
    );
    expect(zhCn.license, 'ECDICT (MIT)');
    expect(zhTw.license, 'ECDICT (MIT)');

    // 主源与镜像只换域名，资源身份（路径/摘要）不变。
    final mainUri = zhCn.fileUri(AsrDownloadSource.huggingFace);
    final mirrorUri = zhCn.fileUri(AsrDownloadSource.huggingFaceMirror);
    expect(mainUri.host, 'huggingface.co');
    expect(mirrorUri.host, 'hf-mirror.com');
    expect(mainUri.path, mirrorUri.path);
    expect(
      mainUri.path,
      '/datasets/banko3/loop-back/resolve/'
      '3b3a5bef53a1c2c86f72117a8ce149554122baac/dict_en_zh-CN-v1.sqlite.zip',
    );
  });

  late Directory fakeAppSupportDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppLogger.instance.clear();
    fakeAppSupportDir = Directory.systemTemp.createTempSync(
      'dict_manager_support_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async {
            if (call.method == 'getApplicationSupportDirectory') {
              return fakeAppSupportDir.path;
            }
            return null;
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (fakeAppSupportDir.existsSync()) {
      fakeAppSupportDir.deleteSync(recursive: true);
    }
  });

  DictionaryDownloadManager manager(
    _MockAdapter adapter, {
    String archiveFileName = 'dict-v1.sqlite.zip',
    String resourceId = 'dict-en_zh-v1',
  }) {
    final dio = Dio();
    dio.httpClientAdapter = adapter;
    final zip = _dictionaryArchivePayload();
    final sha = sha256.convert(zip).toString();
    return DictionaryDownloadManager.withDio(
      dio,
      specs: {
        'zh': DictionarySpec(
          nativeLanguage: 'zh',
          resourceId: resourceId,
          archiveFileName: archiveFileName,
          archiveSha256: sha,
          estimatedDownloadBytes: zip.length,
        ),
      },
    );
  }

  test('download 成功 → 主源 URL 解压为 dict.sqlite 并写入安装清单', () async {
    final payload = _dictionaryArchivePayload();
    const source = AsrDownloadSource.huggingFace;
    final requestedUris = <Uri>[];
    final m = manager(
      _MockAdapter(
        downloadUrl: _publicUri('dict-v1.sqlite.zip', source).toString(),
        payload: payload,
        requestUris: requestedUris,
      ),
    );

    final path = await m.download('zh', source: source);

    expect(requestedUris.single, _publicUri('dict-v1.sqlite.zip', source));
    expect(File(path).existsSync(), isTrue);
    expect(File(path).readAsBytesSync(), List<int>.filled(16, 7));
    final manifest = await readResourceInstallManifest(
      Directory(p.dirname(path)),
    );
    expect(manifest?.resourceId, 'dict-en_zh-v1');
    expect(manifest?.resourceSize, 16);
    expect(
      AppLogger.instance.entries.any(
        (entry) =>
            entry.tag == 'Dict' &&
            entry.message.contains('download finished lang=zh') &&
            entry.message.contains('elapsedMs='),
      ),
      isTrue,
    );
  });

  test('download 使用镜像公开源（同一资源身份只换域名）', () async {
    final payload = _dictionaryArchivePayload();
    const source = AsrDownloadSource.huggingFaceMirror;
    final requestedUris = <Uri>[];
    final m = manager(
      _MockAdapter(
        downloadUrl: _publicUri('dict-v1.sqlite.zip', source).toString(),
        payload: payload,
        requestUris: requestedUris,
      ),
    );

    await m.download('zh', source: source);

    expect(requestedUris.single.host, 'hf-mirror.com');
    expect(
      requestedUris.single.path,
      _publicUri('dict-v1.sqlite.zip', AsrDownloadSource.huggingFace).path,
    );
  });

  test('旧安装（清单 resourceId 匹配）→ 识别为已下载且不重下', () async {
    final dir = Directory(
      p.join(fakeAppSupportDir.path, 'dictionary', 'en_zh'),
    )..createSync(recursive: true);
    File(p.join(dir.path, 'dict.sqlite')).writeAsBytesSync(
      List<int>.filled(8, 1),
    );
    await writeResourceInstallManifest(
      dir,
      resourceId: 'dict-en_zh-v1',
      installAt: DateTime(2024),
    );

    final m = manager(_MockAdapter(downloadUrl: 'http://unused.local/x.zip'));

    expect(await m.isDictionaryDownloaded('zh'), isTrue);
  });

  test('损坏安装（清单缺失）→ 识别为未下载', () async {
    final dir = Directory(
      p.join(fakeAppSupportDir.path, 'dictionary', 'en_zh'),
    )..createSync(recursive: true);
    File(p.join(dir.path, 'dict.sqlite')).writeAsBytesSync(
      List<int>.filled(8, 1),
    );

    final m = manager(_MockAdapter(downloadUrl: 'http://unused.local/x.zip'));

    expect(await m.isDictionaryDownloaded('zh'), isFalse);
  });

  test('归档下载网络失败 → 抛结构化 ReliableDownloadException(httpStatus) 且不留残留', () async {
    const source = AsrDownloadSource.huggingFace;
    final m = manager(
      _MockAdapter(
        downloadUrl: _publicUri('dict-v1.sqlite.zip', source).toString(),
        downloadStatusCode: 404,
      ),
    );

    await expectLater(
      m.download('zh', source: source),
      throwsA(
        isA<ReliableDownloadException>().having(
          (e) => e.kind,
          'kind',
          ReliableDownloadFailure.httpStatus,
        ),
      ),
    );
    expect(
      AppLogger.instance.entries.any(
        (entry) =>
            entry.tag == 'Dict' &&
            entry.message.contains('download failed lang=zh') &&
            entry.message.contains('elapsedMs='),
      ),
      isTrue,
    );

    final dictDir = Directory(
      p.join(fakeAppSupportDir.path, 'dictionary', 'en_zh'),
    );
    final leftovers = dictDir.existsSync()
        ? dictDir.listSync().whereType<File>()
        : const <File>[];
    expect(leftovers, isEmpty);
  });
}

List<int> _dictionaryArchivePayload() {
  final file = ArchiveFile('dict_en_zh-v1.sqlite', 16, List<int>.filled(16, 7))
    ..lastModTime = DateTime.utc(2020).millisecondsSinceEpoch ~/ 1000;
  return ZipEncoder().encode(Archive()..addFile(file));
}
