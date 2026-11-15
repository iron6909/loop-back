/// 孤儿产物文件清理服务。
///
/// app 数据目录下按内容指纹/音频 ID 落盘的产物（音频、字幕、波形）在异常路径下
/// 会留下数据库无引用的「孤儿文件」：中断的导入/下载、删除音频时漏删的波形等。
/// 设置页「清除缓存」调用本服务清扫这些残留。
///
/// 与 [temp_cleanup_service] 的区别：后者清系统临时目录（/tmp、Library/Caches），
/// 本服务清 app 数据目录下的持久产物目录，并依据数据库引用判断孤儿。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/app_data_dir.dart';
import '../utils/file_size.dart';
import '../utils/path_key.dart';
import 'app_logger.dart';
import 'temp_cleanup_service.dart' show CleanupResult;

/// 存放各类持久产物的目录（相对 app 数据根目录），递归扫描。
///
/// `audios` 同时覆盖 `audios/imported`、`audios/community` 子目录，以及旧版本
/// 直接存于 `audios/` 根、用可读文件名的遗留音频（如内置示例与早期导入）。
const _mediaDirs = <String>['audios', 'transcripts'];

/// 波形缓存目录（相对 app 数据根目录）。波形是纯缓存，可由音频随时重建。
const _waveformsDir = 'waveforms';

/// 清扫孤儿音频/字幕文件。
///
/// 扫描 [_mediaDirs] 下所有文件，将其相对 app 数据根目录的路径与
/// [referencedRelPaths] 比对，不在其中的即为孤儿并删除。
/// [referencedRelPaths] 由 `AudioItemDao.getAllReferencedRelPaths()` 提供
/// （含软删行，避免误删软删音频的文件）。
///
/// 单文件删除失败不中断整体清扫，仅记日志。返回累计释放字节数。
Future<CleanupResult> cleanupOrphanMediaFiles({
  required Set<String> referencedRelPaths,
}) async {
  final dataDir = await getAppDataDirectory();
  // 白名单里既有导入时用 p.join 拼出的原生路径，也有内置示例手写的 `/` 路径；
  // 磁盘枚举返回原生分隔符，统一归一后再比，避免把仍被引用的文件当孤儿删掉。
  final keep = {for (final path in referencedRelPaths) pathKey(path)};
  var totalBytes = 0;
  var deletedCount = 0;
  var failedCount = 0;

  for (final relDir in _mediaDirs) {
    final dir = Directory(p.join(dataDir.path, relDir));
    if (!await dir.exists()) continue;
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File) continue;
        final relPath = p.relative(entity.path, from: dataDir.path);
        if (keep.contains(pathKey(relPath))) continue;
        try {
          totalBytes += await entity.length();
          await entity.delete();
          deletedCount++;
        } catch (e) {
          failedCount++;
          AppLogger.log('OrphanCleanup', 'Failed: ${entity.path}: $e');
        }
      }
    } catch (e) {
      AppLogger.log('OrphanCleanup', 'Scan error ${dir.path}: $e');
    }
  }

  AppLogger.log(
    'OrphanCleanup',
    'Media done: deleted=$deletedCount, failed=$failedCount, '
        'freed=${formatBytes(totalBytes)}',
  );
  return CleanupResult(freedBytes: totalBytes);
}

/// 全量删除波形缓存目录。
///
/// 波形是纯缓存，删除后下次打开字幕编辑器会自动重建，故清缓存时整目录清空。
/// 返回释放字节数。
Future<CleanupResult> cleanupAllWaveforms() async {
  final dataDir = await getAppDataDirectory();
  final dir = Directory(p.join(dataDir.path, _waveformsDir));
  if (!await dir.exists()) return const CleanupResult(freedBytes: 0);

  var totalBytes = 0;
  var deletedCount = 0;
  var failedCount = 0;
  try {
    await for (final entity in dir.list()) {
      try {
        if (entity is File) {
          totalBytes += await entity.length();
        } else if (entity is Directory) {
          totalBytes += await calculateDirectorySize(entity);
        }
        await entity.delete(recursive: true);
        deletedCount++;
      } catch (e) {
        failedCount++;
        AppLogger.log('OrphanCleanup', 'Waveform failed: ${entity.path}: $e');
      }
    }
  } catch (e) {
    AppLogger.log('OrphanCleanup', 'Waveform scan error ${dir.path}: $e');
  }

  AppLogger.log(
    'OrphanCleanup',
    'Waveforms done: deleted=$deletedCount, failed=$failedCount, '
        'freed=${formatBytes(totalBytes)}',
  );
  return CleanupResult(freedBytes: totalBytes);
}
