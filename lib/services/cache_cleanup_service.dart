/// 「清除缓存」的编排。
///
/// 一次清理串联 8 个互相独立的副作用：AI 缓存索引、AI 内存缓存、临时目录、网络
/// 图片缓存、词典文件、孤儿媒体、波形缓存、TTS 缓存。顺序与汇总放在这里，具体
/// 副作用由调用方注入（DAO / 顶层清理函数），因此可以脱离 widget 直接测试。
///
/// 任一步失败都不中断后续步骤：清缓存是尽力而为，失败步骤计 0 并写日志，
/// 返回的汇总只统计真正成功的部分。
library;

import 'app_logger.dart';
import '../utils/file_size.dart';

/// 一次清理的结果。
class CacheCleanupResult {
  const CacheCleanupResult({
    required this.deletedIndexRows,
    required this.freedBytes,
  });

  /// 删除的 AI 缓存索引行数；0 表示原本就没有可删的行。
  final int deletedIndexRows;

  /// 各步骤累计释放的磁盘字节数。
  final int freedBytes;

  /// 什么都没删掉（用于「缓存已经是空的」提示）。
  bool get isEmpty => deletedIndexRows == 0 && freedBytes == 0;
}

/// 清缓存步骤的集合，见库注释。
class CacheCleanupService {
  const CacheCleanupService({
    required this.clearAiCacheRows,
    required this.clearAiMemoryCaches,
    required this.clearTempFiles,
    required this.clearNetworkImages,
    required this.clearUnusedDictionaries,
    required this.clearOrphanMediaFiles,
    required this.clearWaveforms,
    required this.clearTtsCache,
  });

  /// 清空 AI 缓存索引，返回删除的行数。
  final Future<int> Function() clearAiCacheRows;

  /// 清空 AI 的内存缓存（句子 AI + AI 词典 L1），无返回值。
  final void Function() clearAiMemoryCaches;

  /// 分别返回各步释放的字节数。
  final Future<int> Function() clearTempFiles;
  final Future<int> Function() clearNetworkImages;
  final Future<int> Function() clearUnusedDictionaries;
  final Future<int> Function() clearOrphanMediaFiles;
  final Future<int> Function() clearWaveforms;
  final Future<int> Function() clearTtsCache;

  /// 依次执行全部步骤，返回汇总结果。
  ///
  /// 顺序固定：先清索引与内存缓存（避免后续步骤命中旧数据），再清磁盘产物。
  Future<CacheCleanupResult> run() async {
    final deletedIndexRows = await _runStep('aiCacheRows', clearAiCacheRows);
    _runSyncStep('aiMemoryCaches', clearAiMemoryCaches);

    var freedBytes = 0;
    freedBytes += await _runStep('tempFiles', clearTempFiles);
    freedBytes += await _runStep('networkImages', clearNetworkImages);
    freedBytes += await _runStep('dictionaries', clearUnusedDictionaries);
    freedBytes += await _runStep('orphanMedia', clearOrphanMediaFiles);
    freedBytes += await _runStep('waveforms', clearWaveforms);
    freedBytes += await _runStep('ttsCache', clearTtsCache);

    AppLogger.log(
      'CacheCleanup',
      '清缓存完成: 索引行 $deletedIndexRows, 释放 ${formatBytes(freedBytes)}',
    );
    return CacheCleanupResult(
      deletedIndexRows: deletedIndexRows,
      freedBytes: freedBytes,
    );
  }

  /// 单步失败只记日志并计 0，不影响其余步骤。
  Future<int> _runStep(String name, Future<int> Function() step) async {
    try {
      return await step();
    } catch (error) {
      AppLogger.log('CacheCleanup', '$name 失败: $error');
      return 0;
    }
  }

  void _runSyncStep(String name, void Function() step) {
    try {
      step();
    } catch (error) {
      AppLogger.log('CacheCleanup', '$name 失败: $error');
    }
  }
}
