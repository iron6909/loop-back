/// Piper VITS 模型下载、校验、缓存管理（按音色，每音色一个独立模型）。
///
/// 音色资源按布局分两类：HF resolve 逐文件（onnx + tokens.txt，共享 espeak 依赖）
/// 与 GitHub 重打包整包（ryan/joe/hfc_female 三个音色，归档自带 espeak-ng-data）。
/// 下载 → 校验 SHA-256 → staging 校验 → 原子替换；共享 espeak-ng-data 缺失时
/// 只补该依赖、不重下模型本体（同 #21 Kokoro 的只补修复）。下载基于
/// `ReliableHttpDownloader`，网络中断保留 `.part`/`.part.meta.json` 供续传。
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_logger.dart';
import '../asr/asr_model_catalog.dart'
    show
        AsrDownloadSource,
        AsrPublicResourceLayout,
        AsrPublicResourceSpec,
        AsrResourceFile;
import '../asr/asr_model_manager.dart'
    show AsrModelDownloadStatus, AsrModelDownloadProgress;
import '../asr/asr_resource_installer.dart'
    show AsrResourceFileDownload, AsrResourceInstaller;
import '../reliable_http_downloader.dart';
import '../resource_archive_installer.dart';
import '../resource_install_manifest.dart';
import 'piper_model_catalog.dart';
import 'tts_espeak_repair.dart'
    show installTtsEspeakData, ttsEspeakDataNeedsRepair;

// 复用 ASR 的下载状态/进度类型（已是通用命名，避免重复定义）。
export '../asr/asr_model_manager.dart'
    show AsrModelDownloadStatus, AsrModelDownloadProgress;

/// Piper 引擎初始化所需的本地绝对路径集合（无 voices.bin）。
class PiperModelPaths {
  /// `*.onnx` 模型绝对路径（如 `en_US-amy-medium.onnx`）。
  final String model;

  /// `tokens.txt` 绝对路径。
  final String tokens;

  /// `espeak-ng-data` 目录绝对路径。
  final String dataDir;

  const PiperModelPaths({
    required this.model,
    required this.tokens,
    required this.dataDir,
  });
}

/// Piper 模型管理器（绑定单个音色 [voice]）。
///
/// 每个音色一个实例（见 `piperModelManagerProvider` 的 family）；方法均针对本实例
/// 绑定的音色操作，互不干扰，故各音色可独立下载/删除/校验。
class PiperModelManager {
  /// `ReliableHttpDownloader` 接口本身不提供释放能力，[dispose] 需要靠持有
  /// 同一个 [_dio] 来关闭底层 HTTP 客户端。
  late final Dio _dio;
  late final ReliableHttpDownloader _downloader;
  late final ResourceArchiveInstaller _archiveInstaller;
  late final AsrResourceInstaller _fileInstaller;

  /// 本管理器绑定的音色（决定目录名/资源/SHA）。
  final PiperVoice voice;

  /// 全部 Piper 公开资源（7 个可下载音色 + 共享 espeak-ng-data）；测试可覆盖。
  final Map<String, AsrPublicResourceSpec> resourceRegistry;

  /// 下载基地址覆盖（仅测试）。
  final String? baseUrlOverride;

  /// 模型存储根目录解析器（仅测试覆盖；默认 `${appSupport}/tts-models`）。
  final Future<String> Function()? modelsRootResolver;

  PiperModelManager({
    required this.voice,
    Dio? dio,
    this.baseUrlOverride,
    this.modelsRootResolver,
    Map<String, AsrPublicResourceSpec>? resourceRegistryOverride,
  }) : resourceRegistry =
           resourceRegistryOverride ?? piperPublicResourceCatalog {
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

  /// 模型存储根目录（与 Kokoro 共用 `tts-models`，各音色子目录隔离）。
  Future<String> get _modelsRoot async {
    if (modelsRootResolver != null) return modelsRootResolver!();
    final appDir = await getApplicationSupportDirectory();
    return p.join(appDir.path, 'tts-models');
  }

  /// 本音色模型本地目录（目录名 = 音色 id）。
  Future<String> modelDir() async => p.join(await _modelsRoot, voice.id);

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
      'PiperModel',
      '检查安装状态 resource=${voice.id} dir=${directory.path} '
          'dirExists=${directory.existsSync()} '
          'manifestExists=${manifestFile.existsSync()}',
    );
    final ResourceInstallManifest? manifest;
    try {
      manifest = await readResourceInstallManifest(directory);
    } on FormatException catch (error) {
      AppLogger.log('PiperModel', 'invalid install manifest: $error');
      return null;
    }
    if (manifest == null) {
      AppLogger.log('PiperModel', '检查结果 resource=${voice.id} manifest=null');
      return null;
    }
    if (manifest.resourceId != voice.id) {
      AppLogger.log(
        'PiperModel',
        '检查结果 resource=${voice.id} manifestResource=${manifest.resourceId} matched=false',
      );
      return null;
    }
    AppLogger.log(
      'PiperModel',
      '检查结果 resource=${voice.id} manifestResource=${manifest.resourceId} '
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

  /// 解析引擎所需文件路径；任一关键文件缺失抛 [StateError]。
  Future<PiperModelPaths> piperConfigPaths() async {
    final dir = Directory(await modelDir());
    final paths = await _resolvePaths(dir);
    if (paths == null) {
      throw StateError('Piper model files missing under ${dir.path}');
    }
    return paths;
  }

  /// 下载并安装模型，通过 [onProgress] 报告进度，可经 [cancelToken] 取消。
  ///
  /// 许可不允许再分发的音色（[voice.resource] 为 null）不提供下载，抛
  /// [StateError]。模型本体齐全、仅 espeak-ng-data 缺失或损坏时只补该依赖。
  Future<String> downloadModel({
    AsrDownloadSource source = AsrDownloadSource.huggingFace,
    void Function(AsrModelDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final spec = voice.resource;
    if (spec == null) {
      throw StateError('Piper voice ${voice.id} is not redistributable');
    }
    final root = Directory(await _modelsRoot);
    final target = Directory(await modelDir());

    // 只补分支：模型本体（onnx/tokens）齐全、仅 espeak-ng-data 缺失或损坏。
    if (await _needsEspeakRepair(target)) {
      AppLogger.log(
        'PiperModel',
        '┌ downloadModel(repair espeak) dir=${target.path}',
      );
      onProgress?.call(
        const AsrModelDownloadProgress(
          status: AsrModelDownloadStatus.downloading,
        ),
      );
      await installTtsEspeakData(
        logTag: 'PiperModel',
        root: root,
        target: target,
        dataDirectoryName: piperDataDirectoryName,
        existingDataDirPath: await _findDir(target, piperDataDirectoryName),
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
        'PiperModel',
        '└ downloadModel(repair espeak) done dir=${target.path}',
      );
      return target.path;
    }

    AppLogger.log('PiperModel', '┌ downloadModel dir=${target.path}');
    onProgress?.call(
      const AsrModelDownloadProgress(
        status: AsrModelDownloadStatus.downloading,
      ),
    );

    if (spec.layout == AsrPublicResourceLayout.githubReleaseAsset) {
      await _installArchiveVoice(
        root: root,
        target: target,
        spec: spec,
        source: source,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
    } else {
      await _installFileVoice(
        root: root,
        target: target,
        spec: spec,
        source: source,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
    }

    onProgress?.call(
      const AsrModelDownloadProgress(
        status: AsrModelDownloadStatus.downloaded,
        progress: 1,
      ),
    );
    AppLogger.log('PiperModel', '└ downloadModel done dir=${target.path}');
    return target.path;
  }

  /// 安装 GitHub 重打包整包音色（归档自带 espeak-ng-data）。
  Future<void> _installArchiveVoice({
    required Directory root,
    required Directory target,
    required AsrPublicResourceSpec spec,
    required AsrDownloadSource source,
    CancelToken? cancelToken,
    void Function(AsrModelDownloadProgress)? onProgress,
  }) async {
    final file = spec.files.single;
    await _archiveInstaller.install(
      root: root,
      target: target,
      resourceId: spec.id,
      archiveFileName: '_download_${spec.id}.tar.gz',
      uri: _uriFor(spec, file, source),
      expectedSha256: file.sha256,
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
      extractAndValidate: (archive, staging) async {
        await extractFileToDisk(archive.path, staging.path);
        if (await _resolvePaths(staging) == null) {
          throw StateError(
            'Piper key files missing after extraction in ${staging.path}',
          );
        }
      },
    );
  }

  /// 安装 HF 逐文件音色：onnx + tokens.txt，再补共享 espeak-ng-data。
  Future<void> _installFileVoice({
    required Directory root,
    required Directory target,
    required AsrPublicResourceSpec spec,
    required AsrDownloadSource source,
    CancelToken? cancelToken,
    void Function(AsrModelDownloadProgress)? onProgress,
  }) async {
    await _fileInstaller.installFiles(
      root: root,
      target: target,
      resourceId: spec.id,
      downloads: [
        for (final file in spec.files)
          AsrResourceFileDownload(
            file: file,
            uri: _uriFor(spec, file, source),
          ),
      ],
      cancelToken: cancelToken,
      onProgress: (value) => onProgress?.call(
        AsrModelDownloadProgress(
          status: AsrModelDownloadStatus.downloading,
          progress: value,
        ),
      ),
      onInstalling: () => onProgress?.call(
        const AsrModelDownloadProgress(
          status: AsrModelDownloadStatus.downloading,
          progress: 1,
        ),
      ),
    );
    await installTtsEspeakData(
      logTag: 'PiperModel',
      root: root,
      target: target,
      dataDirectoryName: piperDataDirectoryName,
      existingDataDirPath: await _findDir(target, piperDataDirectoryName),
      resourceRegistry: resourceRegistry,
      installer: _archiveInstaller,
      source: source,
      uriFor: _uriFor,
      cancelToken: cancelToken,
    );
  }

  /// 模型本体关键文件（onnx/tokens）齐全、仅 `espeak-ng-data/` 缺失或损坏。
  Future<bool> _needsEspeakRepair(Directory target) async {
    if (!target.existsSync()) return false;
    final model = await _findOnnx(target);
    final tokens = await _findFile(target, piperTokensFileName);
    if (model == null || tokens == null) return false;
    return ttsEspeakDataNeedsRepair(
      await _findDir(target, piperDataDirectoryName),
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
      resourceId: voice.id,
      archiveFileName: '_download_${voice.id}.tar.gz',
    );
    await _fileInstaller.discardPartial(root: root, resourceId: voice.id);
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
  /// 兼容归档解包后文件在根目录或某子目录下两种布局。模型按扩展名 `.onnx` 定位
  /// （排除 sherpa 不需要的 `.onnx.json` 元数据）。
  Future<PiperModelPaths?> _resolvePaths(Directory dir) async {
    final model = await _findOnnx(dir);
    final tokens = await _findFile(dir, piperTokensFileName);
    final dataDir = await _findDir(dir, piperDataDirectoryName);
    if (model == null ||
        tokens == null ||
        dataDir == null ||
        ttsEspeakDataNeedsRepair(dataDir)) {
      return null;
    }
    return PiperModelPaths(model: model, tokens: tokens, dataDir: dataDir);
  }

  /// 递归定位首个 `.onnx`（排除 `.onnx.json`）。
  Future<String?> _findOnnx(Directory root) async {
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is File) {
        final name = p.basename(e.path);
        if (name.endsWith('.onnx') && !name.endsWith('.onnx.json')) {
          return e.path;
        }
      }
    }
    return null;
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
