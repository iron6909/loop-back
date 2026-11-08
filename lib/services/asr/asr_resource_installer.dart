import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../app_logger.dart';
import '../reliable_http_downloader.dart';
import '../resource_install_manifest.dart';
import 'asr_model_catalog.dart';

/// 公开来源资源的单个下载项：文件身份 + 本次使用的下载地址。
class AsrResourceFileDownload {
  const AsrResourceFileDownload({required this.file, required this.uri});

  final AsrResourceFile file;
  final Uri uri;
}

/// ASR 资源的下载、断点续传与原子安装流程。
///
/// 三档 Whisper 模型与共享 VAD 都来自固定公开来源：逐文件下载、逐文件校验
/// SHA-256，全部就绪后才写入安装清单并原子替换旧安装。此实现刻意只服务
/// ASR，避免影响既有 TTS 下载安装机制。
class AsrResourceInstaller {
  AsrResourceInstaller(this._downloader, {RenameDirectory? renameDirectory})
    : _renameDirectory = renameDirectory ?? _defaultRenameDirectory;

  /// 目录改名（发布与回滚）的注入点，测试可模拟权限/占用导致的发布失败。
  final RenameDirectory _renameDirectory;

  final ReliableHttpDownloader _downloader;

  static Future<void> _defaultRenameDirectory(String from, String to) async {
    await Directory(from).rename(to);
  }

  /// 逐文件下载公开来源资源：每个文件校验通过后才进入 staging，
  /// 全部文件就绪后写入安装清单并原子替换当前安装。
  ///
  /// 下载中间目录 `_download_<id>/` 保留各文件的 `.part` 与已完成文件，
  /// 断网后重试只补未完成的文件；`identityKey` 为该文件的 SHA-256，
  /// 来源或版本变化时不会与旧断点拼接。
  Future<void> installFiles({
    required Directory root,
    required Directory target,
    required String resourceId,
    required List<AsrResourceFileDownload> downloads,
    CancelToken? cancelToken,
    void Function(double progress)? onProgress,
    void Function()? onInstalling,
  }) async {
    await root.create(recursive: true);
    final downloadDirectory = Directory(
      p.join(root.path, '_download_$resourceId'),
    );
    await downloadDirectory.create(recursive: true);
    await _cleanupOrphanedStagingDirectories(root, resourceId);
    final totalBytes = downloads.fold<int>(
      0,
      (sum, download) => sum + download.file.sizeBytes,
    );
    var completedBytes = 0;
    Directory? staging;
    try {
      for (final download in downloads) {
        final file = download.file;
        final savePath = p.join(downloadDirectory.path, file.name);
        if (await _matchesInstalledFile(savePath, file)) {
          completedBytes += file.sizeBytes;
          _reportProgress(onProgress, completedBytes, totalBytes);
          continue;
        }
        AppLogger.log(
          'AsrInstall',
          'downloading resource=$resourceId file=${file.name} '
              'url=${download.uri}',
        );
        await _downloader.download(
          uri: download.uri,
          savePath: savePath,
          expectedSize: file.sizeBytes,
          identityKey: file.sha256,
          allowResume: true,
          cancelToken: cancelToken,
          onProgress: (received, total) => _reportProgress(
            onProgress,
            completedBytes + received,
            totalBytes,
          ),
        );
        final actualSha256 = await sha256.bind(File(savePath).openRead()).first;
        if (actualSha256.toString() != file.sha256) {
          // 删除损坏文件，避免下一次安装跳过它。
          await _deleteFileQuietly(File(savePath));
          throw StateError(
            'ASR file SHA-256 mismatch: ${file.name} '
            'expected=${file.sha256} actual=$actualSha256',
          );
        }
        completedBytes += file.sizeBytes;
        _reportProgress(onProgress, completedBytes, totalBytes);
      }

      staging = await root.createTemp('_staging_${resourceId}_');
      onInstalling?.call();
      for (final download in downloads) {
        await File(
          p.join(downloadDirectory.path, download.file.name),
        ).rename(p.join(staging.path, download.file.name));
      }
      await writeResourceInstallManifest(
        staging,
        resourceId: resourceId,
        installAt: DateTime.now(),
      );
      await _publish(staging: staging, target: target, resourceId: resourceId);
      await _deleteDirectoryQuietly(downloadDirectory);
      AppLogger.log('AsrInstall', 'install finished resource=$resourceId');
    } finally {
      if (staging != null) await _deleteDirectoryQuietly(staging);
    }
  }

  /// 丢弃用户明确取消的资源下载残留。
  ///
  /// 仅显式取消调用此方法；网络失败和进程中断保留 `.part`，以便后续续传。
  /// 旧版本用整体归档安装，这里同时清理它们遗留的归档半成品。
  Future<void> discardPartial({
    required Directory root,
    required String resourceId,
  }) async {
    final archive = File(p.join(root.path, '_download_$resourceId.zip'));
    await _deleteFileQuietly(archive);
    await _deleteFileQuietly(File('${archive.path}.part'));
    await _deleteFileQuietly(File('${archive.path}.part.meta.json'));
    await _deleteDirectoryQuietly(
      Directory(p.join(root.path, '_download_$resourceId')),
    );
    await _cleanupOrphanedStagingDirectories(root, resourceId);
  }

  void _reportProgress(
    void Function(double progress)? onProgress,
    int completedBytes,
    int totalBytes,
  ) {
    if (onProgress == null || totalBytes <= 0) return;
    onProgress((completedBytes / totalBytes).clamp(0.0, 1.0));
  }

  /// 已下载完成的文件在同一版本重复安装时可跳过，避免整包重下。
  Future<bool> _matchesInstalledFile(String path, AsrResourceFile file) async {
    final existing = File(path);
    if (!existing.existsSync()) return false;
    if (await existing.length() != file.sizeBytes) {
      await _deleteFileQuietly(existing);
      return false;
    }
    final actualSha256 = (await sha256.bind(existing.openRead()).first)
        .toString();
    if (actualSha256 == file.sha256) return true;
    await _deleteFileQuietly(existing);
    return false;
  }

  /// 原子替换：先把旧安装改名为 `.previous`，新安装就位后再删除旧目录。
  /// 新安装就位失败时把旧安装改回去，保证失败不会留下不可用安装。
  Future<void> _publish({
    required Directory staging,
    required Directory target,
    required String resourceId,
  }) async {
    final previous = Directory('${target.path}.previous');
    if (previous.existsSync()) await previous.delete(recursive: true);
    if (target.existsSync()) await _renameDirectory(target.path, previous.path);
    try {
      await _renameDirectory(staging.path, target.path);
    } catch (_) {
      if (previous.existsSync() && !target.existsSync()) {
        await _renameDirectory(previous.path, target.path);
      }
      AppLogger.log('AsrInstall', 'publish failed resource=$resourceId');
      rethrow;
    }
    if (previous.existsSync()) await previous.delete(recursive: true);
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
        await _deleteDirectoryQuietly(entity);
      }
    }
  }

  Future<void> _deleteFileQuietly(File file) async {
    if (!file.existsSync()) return;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await file.delete();
        return;
      } on FileSystemException catch (error, stackTrace) {
        if (attempt == 2) {
          AppLogger.log(
            'AsrInstall',
            'cleanup file failed path=${file.path} error=$error\n$stackTrace',
          );
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> _deleteDirectoryQuietly(Directory directory) async {
    if (!directory.existsSync()) return;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await directory.delete(recursive: true);
        return;
      } on FileSystemException catch (error, stackTrace) {
        if (attempt == 2) {
          AppLogger.log(
            'AsrInstall',
            'cleanup directory failed path=${directory.path} error=$error\n$stackTrace',
          );
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }
}

/// 目录改名注入点。
typedef RenameDirectory = Future<void> Function(String from, String to);
