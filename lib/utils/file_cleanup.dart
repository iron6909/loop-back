/// 尽力而为的文件清理。
///
/// 缓存、临时文件与模型安装残留的删除失败不应该让业务流程失败（Windows 上文件被
/// 播放器、索引服务占用很常见），所以统一吞掉异常但**记一条日志**——按 AGENTS.md
/// §6.5.4，best-effort 清理可以吞，但要可观测。
///
/// 重试沿用模型安装器原来的做法（3 次、间隔 50ms）：Windows 上句柄释放有延迟，
/// 立即放弃会把「稍后就能删」的文件留成孤儿。
library;

import 'dart:io';

import '../services/app_logger.dart';

const String _logTag = 'FileCleanup';
const int _attempts = 3;
const Duration _retryDelay = Duration(milliseconds: 50);

/// 删除文件；不存在或删除失败都不抛异常。
Future<void> deleteFileQuietly(File file) async {
  for (var attempt = 0; attempt < _attempts; attempt++) {
    try {
      if (!await file.exists()) return;
      await file.delete();
      return;
    } on FileSystemException catch (error) {
      if (attempt == _attempts - 1) {
        AppLogger.log(_logTag, '删除文件失败 ${file.path}: $error');
        return;
      }
      await Future<void>.delayed(_retryDelay);
    }
  }
}

/// 递归删除目录；不存在或删除失败都不抛异常。
Future<void> deleteDirectoryQuietly(Directory directory) async {
  for (var attempt = 0; attempt < _attempts; attempt++) {
    try {
      if (!await directory.exists()) return;
      await directory.delete(recursive: true);
      return;
    } on FileSystemException catch (error) {
      if (attempt == _attempts - 1) {
        AppLogger.log(_logTag, '删除目录失败 ${directory.path}: $error');
        return;
      }
      await Future<void>.delayed(_retryDelay);
    }
  }
}
