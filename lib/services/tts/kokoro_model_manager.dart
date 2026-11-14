/// Kokoro 模型下载、校验、缓存管理。
///
/// Kokoro v1.0 的两个变体从上游 Hugging Face 仓库逐文件下载（HF resolve 布局）：
/// 逐文件校验 SHA-256 → staging 组装 → 原子替换模型目录 → 补共享
/// `espeak-ng-data` 依赖。若模型本体齐全、仅该目录缺失或损坏，则只下载独立的
/// `espeak-ng-data` 归档解包进模型目录，不重下模型本体。下载基于
/// `ReliableHttpDownloader`，网络中断时保留 `.part` 供后续 Range 续传。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_logger.dart';
import '../asr/asr_model_catalog.dart'
    show AsrDownloadSource, AsrPublicResourceSpec, AsrResourceFile;
import '../asr/asr_model_manager.dart'
    show AsrModelDownloadStatus, AsrModelDownloadProgress;
import '../asr/asr_resource_installer.dart'
    show AsrResourceFileDownload, AsrResourceInstaller;
import '../reliable_http_downloader.dart';
import '../resource_archive_installer.dart';
import '../resource_install_manifest.dart';
import 'kokoro_model_catalog.dart';
import 'tts_espeak_repair.dart'
    show installTtsEspeakData, ttsEspeakDataNeedsRepair;

// 复用 ASR 的下载状态/进度类型（已是通用命名，避免重复定义）。
export '../asr/asr_model_manager.dart'
    show AsrModelDownloadStatus, AsrModelDownloadProgress;
// 重导出变体枚举，便于管理器使用方（main/provider）无需再单独 import。
export 'tts_engine.dart' show KokoroModelVariant;

/// Kokoro 引擎初始化所需的本地绝对路径集合。
class KokoroModelPaths {
  /// `model.int8.onnx` 绝对路径。
  final String model;

  /// `voices.bin` 绝对路径。
  final String voices;

  /// `tokens.txt` 绝对路径。
  final String tokens;

  /// `espeak-ng-data` 目录绝对路径。
  final String dataDir;

  const KokoroModelPaths({
    required this.model,
    required this.voices,
    required this.tokens,
    required this.dataDir,
  });
}

/// Kokoro 模型管理器（绑定单个变体规格）。
///
/// 每个变体一个实例（见 `kokoroModelManagerProvider` 的 family）；方法均针对
/// 本实例绑定的 [spec] 操作，互不干扰，故各模型可独立下载/删除/校验。
class KokoroModelManager {
  /// `ReliableHttpDownloader` 接口本身不提供释放能力，[dispose] 需要靠持有
  /// 同一个 [_dio] 来关闭底层 HTTP 客户端。
  late final Dio _dio;
  late final ReliableHttpDownloader _downloader;

  /// 归档安装器：只用于共享 `espeak-ng-data` 依赖包（仍以 tar.gz 分发）。
  late final ResourceArchiveInstaller _archiveInstaller;

  /// 逐文件安装器：模型本体（onnx/voices/tokens）走 HF resolve 逐文件下载。
  late final AsrResourceInstaller _fileInstaller;

  /// 本管理器绑定的模型规格（决定目录名/归档/SHA/模型文件名）。
  final KokoroModelSpec spec;

  /// 全部 Kokoro 公开资源（模型 + 共享依赖）；测试可覆盖。
  final Map<String, AsrPublicResourceSpec> resourceRegistry;

  /// 下载基地址覆盖（仅测试）。
  final String? baseUrlOverride;

  /// 模型存储根目录解析器（仅测试覆盖；默认 `${appSupport}/tts-models`）。
  final Future<String> Function()? modelsRootResolver;

  KokoroModelManager({
    Dio? dio,
    KokoroModelSpec? spec,
    this.baseUrlOverride,
    this.modelsRootResolver,
    Map<String, AsrPublicResourceSpec>? resourceRegistryOverride,
  }) : spec = spec ?? kokoroSpecOf(kokoroDefaultVariant),
       resourceRegistry =
           resourceRegistryOverride ?? kokoroPublicResourceCatalog {
    // TTS 模型下载体积较大，但断网时不能无限等待；接收超时只限制长时间无数据。
    _dio =
        dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            sendTimeout: const Duration(seconds: 30),
            receiveTimeout: const Duration(seconds: 30),
          ),
        );
    _downloader = DioReliableHttpDownloader(dio: _dio);
    _archiveInstaller = ResourceArchiveInstaller(_downloader);
    _fileInstaller = AsrResourceInstaller(_downloader);
  }

  /// 模型存储根目录。
  Future<String> get _modelsRoot async {
    if (modelsRootResolver != null) return modelsRootResolver!();
    final appDir = await getApplicationSupportDirectory();
    return p.join(appDir.path, 'tts-models');
  }

  /// Kokoro 模型本地目录。
  Future<String> modelDir() async => p.join(await _modelsRoot, spec.id);

  /// 模型是否已下载且关键文件齐全。
  Future<bool> isModelDownloaded() async {
    final dir = Directory(await modelDir());
    if (!dir.existsSync()) return false;
    return await _resolvePaths(dir) != null;
  }

  /// 读取安装清单；ready 门控不读取 SharedPreferences。
  Future<ResourceInstallManifest?> readInstallManifest() async {
    final directory = Directory(await modelDir());
    final manifestFile = File(p.join(directory.path, 'install.json'));
    AppLogger.log(
      'KokoroModel',
      '检查安装状态 resource=${spec.id} dir=${directory.path} '
          'dirExists=${directory.existsSync()} '
          'manifestExists=${manifestFile.existsSync()}',
    );
    final ResourceInstallManifest? manifest;
    try {
      manifest = await readResourceInstallManifest(directory);
    } on FormatException catch (error) {
      AppLogger.log('KokoroModel', 'invalid install manifest: $error');
      return null;
    }
    if (manifest == null) {
      AppLogger.log('KokoroModel', '检查结果 resource=${spec.id} manifest=null');
      return null;
    }
    if (manifest.resourceId != spec.id) {
      AppLogger.log(
        'KokoroModel',
        '检查结果 resource=${spec.id} manifestResource=${manifest.resourceId} matched=false',
      );
      return null;
    }
    AppLogger.log(
      'KokoroModel',
      '检查结果 resource=${spec.id} manifestResource=${manifest.resourceId} '
          'resourceSize=${manifest.resourceSize} matched=true',
    );
    return manifest;
  }

  /// 兼容旧调用方的安装标记检查。
  Future<bool> hasInstallMarker() async => await readInstallManifest() != null;

  /// 模型本地占用空间（字节，递归统计）。
  Future<int> modelLocalSize() async {
    final dir = Directory(await modelDir());
    if (!dir.existsSync()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  /// 解析引擎所需文件路径；任一关键文件缺失返回 null。
  Future<KokoroModelPaths> kokoroConfigPaths() async {
    final dir = Directory(await modelDir());
    final paths = await _resolvePaths(dir);
    if (paths == null) {
      throw StateError('Kokoro model files missing under ${dir.path}');
    }
    return paths;
  }

  /// 下载并安装模型，通过 [onProgress] 报告进度，可经 [cancelToken] 取消。
  ///
  /// 正常流程：逐文件下载 onnx/voices/tokens → 逐文件校验 SHA-256 → staging 组装
  /// → 原子替换模型目录 → 补共享 `espeak-ng-data`。若模型目录本体齐全、仅
  /// `espeak-ng-data/` 缺失或损坏，则只下载独立 espeak 归档，不重下模型本体。
  Future<String> downloadModel({
    AsrDownloadSource source = AsrDownloadSource.huggingFace,
    void Function(AsrModelDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final root = Directory(await _modelsRoot);
    final target = Directory(await modelDir());

    // 只补分支：模型本体齐全、仅 espeak-ng-data 缺失或损坏时，只下该依赖归档。
    if (await _needsEspeakRepair(target)) {
      AppLogger.log(
        'KokoroModel',
        '┌ downloadModel(repair espeak) dir=${target.path}',
      );
      onProgress?.call(
        const AsrModelDownloadProgress(
          status: AsrModelDownloadStatus.downloading,
        ),
      );
      await installTtsEspeakData(
        logTag: 'KokoroModel',
        root: root,
        target: target,
        dataDirectoryName: kokoroDataDirectoryName,
        existingDataDirPath: await _findDir(target, kokoroDataDirectoryName),
        resourceRegistry: resourceRegistry,
        installer: _archiveInstaller,
        source: source,
        uriFor: _uriFor,
        cancelToken: cancelToken,
      );
      onProgress?.call(
        const AsrModelDownloadProgress(
          status: AsrModelDownloadStatus.downloaded,
          progress: 1,
        ),
      );
      AppLogger.log(
        'KokoroModel',
        '└ downloadModel(repair espeak) done dir=${target.path}',
      );
      return target.path;
    }

    AppLogger.log('KokoroModel', '┌ downloadModel dir=${target.path}');

    onProgress?.call(
      const AsrModelDownloadProgress(
        status: AsrModelDownloadStatus.downloading,
      ),
    );

    await _fileInstaller.installFiles(
      root: root,
      target: target,
      resourceId: spec.id,
      downloads: [
        for (final file in spec.resource.files)
          AsrResourceFileDownload(
            file: file,
            uri: _uriFor(spec.resource, file, source),
          ),
      ],
      cancelToken: cancelToken,
      onProgress: (progress) => onProgress?.call(
        AsrModelDownloadProgress(
          status: AsrModelDownloadStatus.downloading,
          progress: progress,
        ),
      ),
      onInstalling: () => onProgress?.call(
        const AsrModelDownloadProgress(
          status: AsrModelDownloadStatus.downloading,
          progress: 1,
        ),
      ),
    );

    // 共享依赖：模型本体就位后补 espeak-ng-data（v1.0 的英文 G2P 仍走 espeak）。
    await installTtsEspeakData(
      logTag: 'KokoroModel',
      root: root,
      target: target,
      dataDirectoryName: kokoroDataDirectoryName,
      existingDataDirPath: await _findDir(target, kokoroDataDirectoryName),
      resourceRegistry: resourceRegistry,
      installer: _archiveInstaller,
      source: source,
      uriFor: _uriFor,
      cancelToken: cancelToken,
    );

    onProgress?.call(
      const AsrModelDownloadProgress(
        status: AsrModelDownloadStatus.downloaded,
        progress: 1,
      ),
    );
    AppLogger.log('KokoroModel', '└ downloadModel done dir=${target.path}');
    return target.path;
  }

  /// 模型本体关键文件（onnx/voices/tokens）齐全、仅 `espeak-ng-data/` 缺失或损坏。
  Future<bool> _needsEspeakRepair(Directory target) async {
    if (!target.existsSync()) return false;
    final model = await _findFile(target, spec.modelFileName);
    final voices = await _findFile(target, kokoroVoicesFileName);
    final tokens = await _findFile(target, kokoroTokensFileName);
    if (model == null || voices == null || tokens == null) return false;
    return ttsEspeakDataNeedsRepair(
      await _findDir(target, kokoroDataDirectoryName),
    );
  }

  /// 删除本地模型。
  Future<void> deleteModel() async {
    final dir = Directory(await modelDir());
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    await discardPartialDownload();
  }

  /// 清理用户主动取消或删除时遗留的下载归档、续传文件和 staging。
  Future<void> discardPartialDownload() async {
    final root = Directory(await _modelsRoot);
    await _archiveInstaller.discardPartial(
      root: root,
      resourceId: spec.id,
      archiveFileName: '_download_${spec.id}.tar.gz',
    );
    await _fileInstaller.discardPartial(root: root, resourceId: spec.id);
  }

  /// 释放资源。
  void dispose() {
    _dio.close();
  }

  Uri _uriFor(
    AsrPublicResourceSpec resource,
    AsrResourceFile file,
    AsrDownloadSource source,
  ) {
    if (baseUrlOverride != null) {
      return Uri.parse('$baseUrlOverride/${file.name}');
    }
    return resource.fileUri(source, file);
  }

  /// 在 [dir] 下递归定位关键文件；任一缺失返回 null。
  ///
  /// 兼容归档解包后文件在根目录或某子目录下两种布局。
  Future<KokoroModelPaths?> _resolvePaths(Directory dir) async {
    final model = await _findFile(dir, spec.modelFileName);
    final voices = await _findFile(dir, kokoroVoicesFileName);
    final tokens = await _findFile(dir, kokoroTokensFileName);
    final dataDir = await _findDir(dir, kokoroDataDirectoryName);
    if (model == null ||
        voices == null ||
        tokens == null ||
        dataDir == null ||
        ttsEspeakDataNeedsRepair(dataDir)) {
      return null;
    }
    return KokoroModelPaths(
      model: model,
      voices: voices,
      tokens: tokens,
      dataDir: dataDir,
    );
  }

  Future<String?> _findFile(Directory root, String name) async {
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is File && p.basename(e.path) == name) return e.path;
    }
    return null;
  }

  Future<String?> _findDir(Directory root, String name) async {
    if (p.basename(root.path) == name) return root.path;
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is Directory && p.basename(e.path) == name) return e.path;
    }
    return null;
  }
}
