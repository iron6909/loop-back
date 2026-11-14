/// Piper VITS 模型下载状态机 Provider（多音色）。
///
/// 管理 7 个 Piper 音色各自的下载/重试/取消/删除与就绪状态——与 Kokoro 不同，
/// Piper 每音色是一个独立模型，故下载单元是「音色」（key=voiceId）。每个音色一个
/// [PiperModelManager]（`piperModelManagerProvider` 的 family），互不干扰、可独立
/// 下载与删除。引擎当前用哪个音色由 [ttsSettingsProvider] 的 `activePiperVoice`
/// 决定，[piperReadyProvider] 即「当前口音下选中的音色是否就绪」。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/app_logger.dart';
import '../../services/download/download_failure.dart';
import '../../services/reliable_http_downloader.dart';
import '../../services/resource_install_manifest.dart';
import '../../services/tts/piper_model_manager.dart';
import '../../services/tts/piper_model_catalog.dart';
import '../offline_asr_settings_provider.dart' show offlineAsrSettingsProvider;
import 'tts_settings_provider.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// 单个 Piper 音色模型的 UI 状态。
class PiperModelState {
  final AsrModelDownloadStatus downloadStatus;
  final double downloadProgress;
  final int localSizeBytes;
  final ResourceInstallManifest? installManifest;

  /// 失败时的归类原因（供 UI 显本地化文案）；非失败态为 null。
  final DownloadFailureKind? downloadError;

  const PiperModelState({
    this.downloadStatus = AsrModelDownloadStatus.notDownloaded,
    this.downloadProgress = 0,
    this.localSizeBytes = 0,
    this.installManifest,
    this.downloadError,
  });

  /// 模型是否已就绪（可被引擎使用）。
  bool get isReady => downloadStatus == AsrModelDownloadStatus.downloaded;

  /// 是否正在下载。
  bool get isDownloading =>
      downloadStatus == AsrModelDownloadStatus.downloading;

  PiperModelState copyWith({
    AsrModelDownloadStatus? downloadStatus,
    double? downloadProgress,
    int? localSizeBytes,
    ResourceInstallManifest? installManifest,
    bool clearInstallManifest = false,
    DownloadFailureKind? downloadError,
    bool clearError = false,
  }) {
    return PiperModelState(
      downloadStatus: downloadStatus ?? this.downloadStatus,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      localSizeBytes: localSizeBytes ?? this.localSizeBytes,
      installManifest: clearInstallManifest
          ? null
          : (installManifest ?? this.installManifest),
      downloadError: clearError ? null : (downloadError ?? this.downloadError),
    );
  }
}

/// 全部音色合并的状态容器。
class PiperModelsState {
  final Map<String, PiperModelState> byVoiceId;

  const PiperModelsState(this.byVoiceId);

  /// 全部未下载的初始态。
  factory PiperModelsState.initial() => const PiperModelsState({});

  /// 取某音色状态（缺省为未下载）。
  PiperModelState of(String voiceId) =>
      byVoiceId[voiceId] ?? const PiperModelState();

  /// 返回替换了某音色状态的新容器。
  PiperModelsState withVoice(String voiceId, PiperModelState s) {
    return PiperModelsState({...byVoiceId, voiceId: s});
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// TTS 模型状态只在当前进程内存中维护，启动时不从 SP 恢复。
final initialPiperModelStateProvider = Provider<PiperModelsState>(
  (ref) => PiperModelsState.initial(),
);

/// Piper 模型管理器（按音色 id 的 family，各自绑定音色）。
final piperModelManagerProvider = Provider.family<PiperModelManager, String>((
  ref,
  voiceId,
) {
  final voice = piperVoiceById(voiceId) ?? piperVoices.first;
  final manager = PiperModelManager(voice: voice);
  ref.onDispose(manager.dispose);
  return manager;
});

/// Piper 模型状态 Provider（全局单例）。
final piperModelProvider =
    NotifierProvider<PiperModelNotifier, PiperModelsState>(
      PiperModelNotifier.new,
    );

/// 当前口音下**选中音色**是否就绪（供控制器决定有效引擎）。
final piperReadyProvider = Provider<bool>((ref) {
  final voiceId = ref.watch(
    ttsSettingsProvider.select((s) => s.activePiperVoice),
  );
  return ref.watch(piperModelProvider).of(voiceId).isReady;
});

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

class PiperModelNotifier extends Notifier<PiperModelsState> {
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, Future<void>> _downloadTasks = {};
  final Set<String> _checkingInstallMarkers = {};
  final Map<String, int> _downloadSessions = {};
  final Set<String> _cancellingVoiceIds = {};
  int _nextDownloadSession = 0;

  @override
  PiperModelsState build() {
    ref.onDispose(() {
      for (final t in _cancelTokens.values) {
        t.cancel();
      }
    });
    return ref.read(initialPiperModelStateProvider);
  }

  void _set(String voiceId, PiperModelState s) {
    state = state.withVoice(voiceId, s);
  }

  /// 将磁盘安装标记同步到本次进程内存状态。
  void markReady(String voiceId, ResourceInstallManifest manifest) {
    _set(
      voiceId,
      state
          .of(voiceId)
          .copyWith(
            downloadStatus: AsrModelDownloadStatus.downloaded,
            downloadProgress: 1,
            localSizeBytes: manifest.resourceSize,
            installManifest: manifest,
          ),
    );
  }

  /// 检查全部音色的安装标记并同步本次进程内存状态，不触发下载。
  Future<void> refreshInstalledStates({bool Function()? shouldCommit}) async {
    await Future.wait(
      piperVoices.map((voice) async {
        final manager = ref.read(piperModelManagerProvider(voice.id));
        final before = state.of(voice.id).downloadStatus;
        final manifest = await manager.readInstallManifest();
        final filesReady = await manager.isModelDownloaded();
        if (shouldCommit != null && !shouldCommit()) return;
        final current = state.of(voice.id);
        if (manifest != null && filesReady) {
          markReady(voice.id, manifest);
        } else if (!current.isDownloading) {
          _set(
            voice.id,
            state
                .of(voice.id)
                .copyWith(
                  downloadStatus: AsrModelDownloadStatus.notDownloaded,
                  downloadProgress: 0,
                  clearInstallManifest: true,
                ),
          );
        }
        AppLogger.log(
          'PiperModel',
          '刷新内存状态 voice=${voice.id} before=$before '
              'manifest=${manifest == null ? 'missing' : 'matched'} '
              'filesReady=$filesReady '
              'after=${state.of(voice.id).downloadStatus}',
        );
      }),
    );
  }

  /// 确保某音色就绪：未就绪且未在下载则触发下载。
  Future<void> ensureDownloaded(String voiceId) async {
    final s = state.of(voiceId);
    if (s.isReady ||
        s.isDownloading ||
        s.downloadStatus == AsrModelDownloadStatus.failed ||
        _cancellingVoiceIds.contains(voiceId)) {
      return;
    }
    if (!_checkingInstallMarkers.add(voiceId)) return;
    try {
      final manager = ref.read(piperModelManagerProvider(voiceId));
      final manifest = await manager.readInstallManifest();
      // 安装清单存在但模型文件被外部损坏（如 espeak-ng-data 被删）时，
      // 不能仅凭清单误报就绪：还需校验关键文件齐全，缺失则走修复下载。
      final filesReady = await manager.isModelDownloaded();
      if (manifest != null && filesReady) {
        markReady(voiceId, manifest);
        return;
      }
      await _download(voiceId);
    } finally {
      _checkingInstallMarkers.remove(voiceId);
    }
  }

  /// 重试下载（清除错误后重新下载）。
  Future<void> retryDownload(String voiceId) async {
    _set(voiceId, state.of(voiceId).copyWith(clearError: true));
    await _download(voiceId);
  }

  /// 取消某音色正在进行的下载。
  Future<void> cancelDownload(String voiceId) async {
    final task = _downloadTasks[voiceId];
    final session = _downloadSessions.remove(voiceId);
    _cancelTokens.remove(voiceId)?.cancel();
    if (session == null) return;
    _cancellingVoiceIds.add(voiceId);
    // UI 立即回到未下载，归档清理继续在后台安全完成。
    _set(
      voiceId,
      const PiperModelState(
        downloadStatus: AsrModelDownloadStatus.notDownloaded,
      ),
    );
    // 等待归档下载退出后再清理，避免取消残留被错误归类为下载失败。
    try {
      await task;
      final manager = ref.read(piperModelManagerProvider(voiceId));
      await manager.deleteModel();
    } finally {
      _cancellingVoiceIds.remove(voiceId);
    }
  }

  /// 删除某音色本地模型。
  Future<void> deleteModel(String voiceId) async {
    final manager = ref.read(piperModelManagerProvider(voiceId));
    await manager.deleteModel();
    _set(
      voiceId,
      const PiperModelState(
        downloadStatus: AsrModelDownloadStatus.notDownloaded,
      ),
    );
  }

  Future<void> _download(String voiceId) async {
    // 先**同步**置为下载中，再做任何 await（同 Kokoro：避免 ensureDownloaded 的
    // 「未在下载」判定与状态翻转之间的 await 窗口被第二次调用漏过、起两路下载）。
    _set(
      voiceId,
      state
          .of(voiceId)
          .copyWith(
            downloadStatus: AsrModelDownloadStatus.downloading,
            downloadProgress: 0,
            clearError: true,
            clearInstallManifest: true,
          ),
    );
    final session = ++_nextDownloadSession;
    final cancelToken = CancelToken();
    _cancelTokens[voiceId] = cancelToken;
    _downloadSessions[voiceId] = session;
    final task = _runDownload(voiceId, session, cancelToken);
    _downloadTasks[voiceId] = task;
    try {
      await task;
    } finally {
      if (identical(_downloadTasks[voiceId], task)) {
        _downloadTasks.remove(voiceId);
      }
    }
  }

  bool _isCurrent(String voiceId, int session, CancelToken cancelToken) =>
      _downloadSessions[voiceId] == session &&
      identical(_cancelTokens[voiceId], cancelToken);

  Future<void> _runDownload(
    String voiceId,
    int session,
    CancelToken cancelToken,
  ) async {
    final manager = ref.read(piperModelManagerProvider(voiceId));
    try {
      await manager.downloadModel(
        // 下载源由系统地区决定（中国区→镜像），与语音识别/词典共用同一份设置。
        source: ref.read(offlineAsrSettingsProvider).downloadSource,
        cancelToken: cancelToken,
        onProgress: (p) {
          if (!_isCurrent(voiceId, session, cancelToken)) return;
          _set(
            voiceId,
            state.of(voiceId).copyWith(downloadProgress: p.progress),
          );
        },
      );
      if (!_isCurrent(voiceId, session, cancelToken)) return;
      final manifest = await manager.readInstallManifest();
      if (manifest == null) {
        throw StateError('Piper install manifest missing after download');
      }
      if (!_isCurrent(voiceId, session, cancelToken)) return;
      _set(
        voiceId,
        state
            .of(voiceId)
            .copyWith(
              downloadStatus: AsrModelDownloadStatus.downloaded,
              downloadProgress: 1.0,
              localSizeBytes: manifest.resourceSize,
              installManifest: manifest,
            ),
      );
      if (_isCurrent(voiceId, session, cancelToken)) {
        _cancelTokens.remove(voiceId);
        _downloadSessions.remove(voiceId);
      }
    } catch (e) {
      if (!_isCurrent(voiceId, session, cancelToken)) return;
      // 取消不是失败：恢复未下载态，不显错误。
      final isCancelled =
          (e is DioException && e.type == DioExceptionType.cancel) ||
          (e is ReliableDownloadException &&
              e.kind == ReliableDownloadFailure.cancelled);
      if (isCancelled) {
        _set(
          voiceId,
          state
              .of(voiceId)
              .copyWith(
                downloadStatus: AsrModelDownloadStatus.notDownloaded,
                downloadProgress: 0,
              ),
        );
      } else {
        AppLogger.log('PiperModel', '✗ download failed ($voiceId): $e');
        _set(
          voiceId,
          state
              .of(voiceId)
              .copyWith(
                downloadStatus: AsrModelDownloadStatus.failed,
                downloadError: classifyDownloadFailure(e),
              ),
        );
      }
      _cancelTokens.remove(voiceId);
      _downloadSessions.remove(voiceId);
    }
  }
}
