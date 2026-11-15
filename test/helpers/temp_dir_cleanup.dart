import 'dart:io';

/// 测试收尾删除临时目录。
///
/// Windows 上 native 播放器与 SQLite 可能短暂持有目录/文件句柄，直接删会抛
/// `PathAccessException (errno 32)`，把已经通过断言的用例判成失败。这里做少量
/// 重试；仍失败就放弃——目录在系统临时目录里，交给 OS 回收，不影响任何断言。
Future<void> deleteTempDirQuietly(Directory dir) async {
  for (var attempt = 0; attempt < 3; attempt += 1) {
    if (!await dir.exists()) return;
    try {
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
