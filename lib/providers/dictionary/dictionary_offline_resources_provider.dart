/// 词典设置页「离线资源」区依赖的逐语言词典安装状态。
///
/// 词典只随当前母语自动下载，[dictionaryProvider] 只承载当前母语的下载态。
/// 设置页需要同时展示 zh-CN / zh-TW 两个变体，因此这里补一个只读的逐语言
/// 本地安装检查：非当前母语已安装即显示「已下载」，否则显示「未下载」。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/dictionary_download_manager.dart';

/// 指定母语词典是否已安装（仅本地检查，不触发下载）。
final dictionaryInstalledProvider = FutureProvider.family<bool, String>((
  ref,
  nativeLanguage,
) async {
  final manager = DictionaryDownloadManager();
  try {
    return await manager.isDictionaryDownloaded(nativeLanguage);
  } finally {
    manager.dispose();
  }
});
