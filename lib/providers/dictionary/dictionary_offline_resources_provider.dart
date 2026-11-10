/// 词典设置页「离线资源」区依赖的逐语言词典状态。
///
/// 词典只随当前母语自动下载，[dictionaryProvider] 只承载当前母语的下载态。
/// 设置页需要同时展示 zh-CN / zh-TW 两个变体，因此这里补一个逐语言的安装检查
/// 与按需下载入口：非当前母语已安装即显示「已下载」，未安装给出下载/重试入口。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/app_logger.dart';
import '../../services/dictionary_download_manager.dart';
import '../../services/download/download_failure.dart';
import '../../services/reliable_http_downloader.dart';
import '../dictionary_provider.dart';
import '../offline_asr_settings_provider.dart';

/// 单个语言变体离线词典的安装/下载状态。
class DictionaryResourceState {
  const DictionaryResourceState({
    this.status,
    this.progress = 0,
    this.failure,
  });

  /// 本地安装检查完成后的下载状态；null 表示仍在检查（显式 loading 态）。
  final DictionaryStatus? status;

  /// 下载进度（0.0-1.0），仅在 [status] 为 [DictionaryStatus.downloading] 时有意义。
  final double progress;

  /// 失败归类，仅在 [status] 为 [DictionaryStatus.failed] 时有值。
  final DownloadFailureKind? failure;

  /// 是否仍在做本地安装检查（此时不应渲染为「未下载」）。
  bool get isChecking => status == null;
}

/// 指定母语词典的安装检查与按需下载状态（设置页非当前母语变体使用）。
final dictionaryResourceProvider = NotifierProvider.family<
    DictionaryResourceNotifier, DictionaryResourceState, String>(
  DictionaryResourceNotifier.new,
);

/// 逐语言词典的只读安装检查 + 按需下载，复用
/// [DictionaryDownloadManager] 的同一套校验与失败归类。
class DictionaryResourceNotifier
    extends FamilyNotifier<DictionaryResourceState, String> {
  CancelToken? _cancelToken;
  late final DictionaryDownloadManager _manager = DictionaryDownloadManager();

  @override
  DictionaryResourceState build(String arg) {
    ref.onDispose(() {
      _cancelToken?.cancel('provider disposed');
      _manager.dispose();
    });
    // 异步本地检查：完成前保持 checking 态，避免瞬时闪烁成「未下载」。
    _checkInstalled(arg);
    return const DictionaryResourceState();
  }

  Future<void> _checkInstalled(String nativeLanguage) async {
    final installed = await _manager.isDictionaryDownloaded(nativeLanguage);
    // 检查期间若已发起下载，丢弃迟到的检查结果，避免覆盖下载状态。
    if (state.status != null) return;
    state = DictionaryResourceState(
      status: installed
          ? DictionaryStatus.downloaded
          : DictionaryStatus.notDownloaded,
    );
  }

  /// 开始下载（未下载时）。
  Future<void> download() => _startDownload();

  /// 重试下载（失败后）。
  Future<void> retryDownload() => _startDownload();

  Future<void> _startDownload() async {
    final nativeLanguage = arg;
    _cancelToken?.cancel('new dictionary download');
    _cancelToken = CancelToken();
    state = const DictionaryResourceState(
      status: DictionaryStatus.downloading,
    );
    try {
      await _manager.download(
        nativeLanguage,
        source: ref.read(offlineAsrSettingsProvider).downloadSource,
        onProgress: (progress) {
          state = DictionaryResourceState(
            status: DictionaryStatus.downloading,
            progress: progress,
          );
        },
        cancelToken: _cancelToken,
      );
      AppLogger.log('Dict', 'variant download complete lang=$nativeLanguage');
      state = const DictionaryResourceState(
        status: DictionaryStatus.downloaded,
        progress: 1,
      );
    } catch (error) {
      final isCancelled =
          (error is DioException && error.type == DioExceptionType.cancel) ||
          (error is ReliableDownloadException &&
              error.kind == ReliableDownloadFailure.cancelled);
      if (isCancelled) return;
      AppLogger.log(
        'Dict',
        'variant download failed lang=$nativeLanguage error=$error',
      );
      state = DictionaryResourceState(
        status: DictionaryStatus.failed,
        failure: classifyDownloadFailure(error),
      );
    }
  }
}
