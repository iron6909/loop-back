/// ASR 模型下载、原子安装和缓存管理。
library;

export 'asr_model_catalog.dart';

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_logger.dart';
import '../reliable_http_downloader.dart';
import '../resource_install_manifest.dart';
import 'asr_model_catalog.dart';
import 'asr_resource_installer.dart';
import 'offline_asr_engine.dart';

/// 三档本机模型保留既有内部 ID 与安装目录，只展示真实模型身份。
final List<AsrModelInfo> availableModels = [
  const AsrModelInfo(
    id: 'whisper-tiny-en-int8',
    displayName: 'Whisper Tiny (English)',
    type: AsrModelType.whisper,
  ),
  const AsrModelInfo(
    id: 'whisper-base-en-int8',
    displayName: 'Whisper Base (English)',
    type: AsrModelType.whisper,
  ),
  const AsrModelInfo(
    id: 'whisper-small-en-int8',
    displayName: 'Whisper Small (English)',
    type: AsrModelType.whisper,
  ),
];

enum AsrModelDownloadStatus { notDownloaded, downloading, downloaded, failed }

class AsrModelDownloadProgress {
  const AsrModelDownloadProgress({
    required this.status,
    this.progress = 0,
    this.error,
  });
  final AsrModelDownloadStatus status;
  final double progress;
  final String? error;
  static const notDownloaded = AsrModelDownloadProgress(
    status: AsrModelDownloadStatus.notDownloaded,
  );
}

/// 统一使用校验、staging 和原子替换的 ASR 安装器。
class AsrModelManager {
  AsrModelManager({
    Dio? dio,
    Map<String, AsrPublicResourceSpec>? resourceRegistryOverride,
    ReliableHttpDownloader? downloader,
    RenameDirectory? renameDirectory,
    this.modelsRootResolver,
  }) : resourceRegistry = resourceRegistryOverride ?? asrPublicResourceCatalog {
    _dio =
        dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            sendTimeout: const Duration(seconds: 30),
            receiveTimeout: const Duration(seconds: 30),
          ),
        );
    _downloader = downloader ?? DioReliableHttpDownloader(dio: _dio);
    _installer = AsrResourceInstaller(
      _downloader,
      renameDirectory: renameDirectory,
    );
  }

  late final Dio _dio;
  late final ReliableHttpDownloader _downloader;
  late final AsrResourceInstaller _installer;

  /// 全部 ASR 资源清单：三档模型与共享 VAD 都来自固定公开来源。
  final Map<String, AsrPublicResourceSpec> resourceRegistry;
  final Future<String> Function()? modelsRootResolver;

  Future<String> get _modelsRoot async {
    final resolver = modelsRootResolver;
    if (resolver != null) return resolver();
    return p.join((await getApplicationSupportDirectory()).path, 'asr-models');
  }

  Future<String> modelDir(String modelId) async =>
      p.join(await _modelsRoot, modelId);

  /// 读取安装清单，并确认清单声明的每个文件都存在且字节数符合目录规格。
  ///
  /// 这里是安装状态的唯一真相。只比尺寸、不做全量 SHA-256：启动扫描要读取数
  /// 百 MB 权重会拖慢首次进入识别设置；逐文件摘要校验在安装与修复流程中执行，
  /// 因此被截断或不完整的安装会回到“未安装”，用户重下即可修复。
  Future<ResourceInstallManifest?> readInstallManifest(String modelId) async {
    final spec = resourceRegistry[modelId];
    if (spec == null) return null;
    final directory = Directory(await modelDir(modelId));
    try {
      final manifest = await readResourceInstallManifest(directory);
      if (manifest == null || manifest.resourceId != modelId) return null;
      for (final requiredFile in spec.files) {
        final file = File(p.join(directory.path, requiredFile.name));
        if (!file.existsSync()) return null;
        if (await file.length() != requiredFile.sizeBytes) return null;
      }
      return manifest;
    } on FormatException {
      return null;
    }
  }

  /// 资源自身及其 catalog 声明的共享依赖均完整时才可供引擎使用。
  Future<bool> isModelDownloaded(String modelId) async {
    final spec = resourceRegistry[modelId];
    if (spec == null || await readInstallManifest(modelId) == null) {
      return false;
    }
    for (final dependency in spec.dependencies) {
      if (!await isModelDownloaded(dependency)) return false;
    }
    return true;
  }

  Future<int> modelLocalSize(String modelId) async =>
      (await readInstallManifest(modelId))?.resourceSize ?? 0;

  /// 下载资源本体（含缺失的共享依赖），逐文件校验通过后才原子替换当前安装。
  ///
  /// 已安装的资源不会重复下载；主模型已安装但共享 VAD 缺失时只补 VAD。
  /// [source] 只改变下载域名，不改变被信任的版本与摘要。
  Future<String> downloadModel(
    String modelId, {
    AsrDownloadSource source = AsrDownloadSource.huggingFace,
    void Function(AsrModelDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final spec = resourceRegistry[modelId];
    if (spec == null) throw ArgumentError('Unknown model: $modelId');
    final target = Directory(await modelDir(modelId));
    if (await readInstallManifest(modelId) == null) {
      onProgress?.call(
        const AsrModelDownloadProgress(
          status: AsrModelDownloadStatus.downloading,
        ),
      );
      await _installResource(
        spec,
        source: source,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
    }
    // 共享依赖单独补齐：缺 VAD 只补 VAD，不重复下载完整模型。
    for (final dependency in spec.dependencies) {
      if (await isModelDownloaded(dependency)) continue;
      final dependencySpec = resourceRegistry[dependency];
      if (dependencySpec == null) {
        throw StateError('Unknown ASR dependency: $dependency');
      }
      await _installResource(
        dependencySpec,
        source: source,
        cancelToken: cancelToken,
      );
    }
    final result = await validateModel(modelId);
    if (!result.isValid) throw StateError(result.describe());
    onProgress?.call(
      const AsrModelDownloadProgress(
        status: AsrModelDownloadStatus.downloaded,
        progress: 1,
      ),
    );
    return target.path;
  }

  Future<AsrModelValidationResult> validateModel(String modelId) async =>
      (await readInstallManifest(modelId)) == null
      ? AsrModelValidationResult(
          modelId: modelId,
          isValid: false,
          reason: 'Missing or invalid install manifest',
        )
      : AsrModelValidationResult(modelId: modelId, isValid: true);

  /// 校验旧逐文件目录，用于把历史可用缓存转换为新的安装清单。
  ///
  /// 旧布局与本票的公开文件字节一致，因此直接按目录规格的 SHA-256 判断：
  /// 一致才写入安装清单，不重下；不一致则保留旧文件并走重新安装（修复）。
  Future<bool> validateLegacyModelFiles(String modelId) async {
    final spec = resourceRegistry[modelId];
    if (spec == null) return false;
    final dir = Directory(await modelDir(modelId));
    for (final file in spec.files) {
      final installed = File(p.join(dir.path, file.name));
      if (!installed.existsSync()) return false;
      if (await _sha256(installed) != file.sha256) return false;
    }
    return true;
  }

  Future<void> deleteModel(String modelId) async {
    final dir = Directory(await modelDir(modelId));
    if (dir.existsSync()) await dir.delete(recursive: true);
    await discardPartialDownload(modelId);
  }

  /// 丢弃指定资源的续传缓存，但不影响已经安装完成的模型目录。
  ///
  /// 下载模型时用户主动取消，需要清理模型本体和共享 VAD 两类资源的半成品。
  Future<void> discardPartialDownload(String modelId) async {
    await _installer.discardPartial(
      root: Directory(await _modelsRoot),
      resourceId: modelId,
    );
  }

  Future<void> cleanupUnknownModels() async {
    final root = Directory(await _modelsRoot);
    if (!root.existsSync()) return;
    await for (final entity in root.list()) {
      if (entity is Directory &&
          !resourceRegistry.containsKey(p.basename(entity.path))) {
        AppLogger.log('ASRModel', '清理旧模型: ${p.basename(entity.path)}');
        await entity.delete(recursive: true);
      }
    }
  }

  AsrModelInfo recommendModel({int ramBytes = 0}) =>
      availableModels.firstWhere((model) => model.id == 'whisper-base-en-int8');
  void dispose() => _dio.close();

  /// 逐文件安装一个公开资源：全部文件校验通过才发布，失败保留旧安装。
  Future<void> _installResource(
    AsrPublicResourceSpec spec, {
    required AsrDownloadSource source,
    CancelToken? cancelToken,
    void Function(AsrModelDownloadProgress)? onProgress,
  }) async {
    await _installer.installFiles(
      root: Directory(await _modelsRoot),
      target: Directory(await modelDir(spec.id)),
      resourceId: spec.id,
      downloads: [
        for (final file in spec.files)
          AsrResourceFileDownload(file: file, uri: spec.fileUri(source, file)),
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
  }

  Future<String> _sha256(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
}

class AsrModelValidationResult {
  const AsrModelValidationResult({
    required this.modelId,
    required this.isValid,
    this.reason,
  });
  final String modelId;
  final bool isValid;
  final String? reason;
  String describe() => isValid
      ? 'Model validation passed: $modelId'
      : 'Downloaded model failed integrity check: $modelId | reason=$reason';
}
