import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'reliable_http_downloader.dart';
import 'resource_install_manifest.dart';
import '../utils/file_cleanup.dart';

/// 固定 CDN 资源归档的通用下载与原子安装流程。
///
/// 资源自身只负责把归档解压并校验到 staging 目录，下载、校验、替换、清理
/// 和安装清单始终走同一套实现，避免词典与发音包产生行为差异。
class ResourceArchiveInstaller {
  ResourceArchiveInstaller(this._downloader);

  final ReliableHttpDownloader _downloader;

  Future<void> install({
    required Directory root,
    required Directory target,
    Directory? downloadDirectory,
    required String resourceId,
    required Uri uri,
    required String? expectedSha256,
    String? archiveFileName,
    required Future<void> Function(File archive, Directory staging)
    extractAndValidate,
    CancelToken? cancelToken,
    void Function(double progress)? onProgress,
    void Function()? onInstalling,
  }) async {
    await root.create(recursive: true);
    final downloadRoot = downloadDirectory ?? root;
    await downloadRoot.create(recursive: true);
    final archive = File(
      p.join(downloadRoot.path, archiveFileName ?? '_download_$resourceId.zip'),
    );
    await _cleanupOrphanedStagingDirectories(root, resourceId);
    Directory? staging;
    try {
      AppLogger.log(
        'ResourceInstall',
        'downloading resource=$resourceId url=$uri',
      );
      await _downloader.download(
        uri: uri,
        savePath: archive.path,
        identityKey: expectedSha256,
        allowResume: true,
        cancelToken: cancelToken,
        onProgress: (received, total) {
          if (total != null && total > 0) {
            onProgress?.call((received / total).clamp(0.0, 1.0));
          }
        },
      );
      if (expectedSha256 != null && expectedSha256.isNotEmpty) {
        final actualSha256 = await sha256.bind(archive.openRead()).first;
        if (actualSha256.toString() != expectedSha256) {
          throw StateError(
            'Resource archive SHA-256 mismatch: expected=$expectedSha256 '
            'actual=$actualSha256',
          );
        }
      }
      AppLogger.log(
        'ResourceInstall',
        'archive verified resource=$resourceId bytes=${await archive.length()}',
      );
      staging = await root.createTemp('_staging_${resourceId}_');
      onInstalling?.call();
      await extractAndValidate(archive, staging);
      await writeResourceInstallManifest(
        staging,
        resourceId: resourceId,
        installAt: DateTime.now(),
      );
      AppLogger.log(
        'ResourceInstall',
        'install manifest written resource=$resourceId',
      );

      final previous = Directory('${target.path}.previous');
      if (previous.existsSync()) await previous.delete(recursive: true);
      if (target.existsSync()) await target.rename(previous.path);
      try {
        await staging.rename(target.path);
      } catch (_) {
        if (previous.existsSync() && !target.existsSync()) {
          await previous.rename(target.path);
        }
        rethrow;
      }
      if (previous.existsSync()) await previous.delete(recursive: true);
      AppLogger.log('ResourceInstall', 'install finished resource=$resourceId');
    } finally {
      await deleteFileQuietly(archive);
      if (staging != null) await deleteDirectoryQuietly(staging);
    }
  }

  /// 清理用户主动取消时不再需要的完整归档、续传文件和 staging。
  ///
  /// 网络失败和进程中断不会调用此方法，以便下一次下载继续使用 HTTP Range。
  Future<void> discardPartial({
    required Directory root,
    Directory? downloadDirectory,
    required String resourceId,
    String? archiveFileName,
  }) async {
    final downloadRoot = downloadDirectory ?? root;
    final archive = File(
      p.join(downloadRoot.path, archiveFileName ?? '_download_$resourceId.zip'),
    );
    await deleteFileQuietly(archive);
    await deleteFileQuietly(File('${archive.path}.part'));
    await deleteFileQuietly(File('${archive.path}.part.meta.json'));
    await _cleanupOrphanedStagingDirectories(root, resourceId);
  }

  Future<void> _cleanupOrphanedStagingDirectories(
    Directory root,
    String resourceId,
  ) async {
    if (!root.existsSync()) return;
    final prefix = '_staging_${resourceId}_';
    final legacyName = '_staging_$resourceId';
    await for (final entity in root.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory &&
          (name == legacyName || name.startsWith(prefix))) {
        await deleteDirectoryQuietly(entity);
      }
    }
  }
}
