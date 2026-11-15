/// 路径比较键。
///
/// 同一个文件在不同来源下写法不同：磁盘枚举（`Directory.list`）在 Windows 返回
/// `audios\imported\x.mp3`，而代码里手写的相对路径、TTS 合成输出常是
/// `audios/imported/x.mp3`。直接把两者放进 Set 比较，会把同一文件当成两个路径——
/// 清缓存时就会把仍被数据库引用的文件误判成孤儿删掉（Windows 上实测）。
///
/// 统一分隔符为 `/` 并折叠 `.`/`..` 后再比较，跨平台都成立。
library;

import 'package:path/path.dart' as p;

/// 把路径归一成可比较的键（`/` 分隔、无 `.`/`..` 冗余段）。空串原样返回。
String pathKey(String path) {
  if (path.isEmpty) return path;
  return p.posix.normalize(path.replaceAll('\\', '/'));
}
