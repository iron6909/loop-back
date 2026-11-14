import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:loop_back/providers/offline_asr_settings_provider.dart';
import 'package:loop_back/providers/asr_engine_provider.dart';
import 'package:loop_back/services/asr/asr_model_manager.dart';
import 'package:loop_back/services/asr/offline_asr_engine.dart';
import 'package:loop_back/services/download/download_failure.dart';
import 'package:loop_back/services/reliable_http_downloader.dart';

class _FakeAsrModelManager extends AsrModelManager {
  _FakeAsrModelManager({
    required this.downloaded,
    required this.localSizeBytes,
  });

  final bool downloaded;
  final int localSizeBytes;
  int deleteModelCallCount = 0;
  int discardPartialDownloadCallCount = 0;

  @override
  Future<bool> isModelDownloaded(String modelId) async => downloaded;

  @override
  Future<int> modelLocalSize(String modelId) async => localSizeBytes;

  @override
  Future<void> deleteModel(String modelId) async {
    deleteModelCallCount += 1;
  }

  @override
  Future<void> cleanupUnknownModels() async {}

  @override
  Future<void> discardPartialDownload(String modelId) async {
    discardPartialDownloadCallCount += 1;
  }
}

class _TestOfflineAsrSettingsNotifier extends OfflineAsrSettingsNotifier {
  _TestOfflineAsrSettingsNotifier(this._initialState);

  final OfflineAsrSettingsState _initialState;

  @override
  OfflineAsrSettingsState build() => _initialState;
}

/// 下载成功的模型管理器：只记录安装请求，不触碰真实文件与网络。
class _SuccessfulDownloadAsrModelManager extends _FakeAsrModelManager {
  _SuccessfulDownloadAsrModelManager()
    : super(downloaded: false, localSizeBytes: 153 * 1024 * 1024);

  final downloadedModelIds = <String>[];

  @override
  Future<String> modelDir(String modelId) async => '/tmp/asr-models/$modelId';

  @override
  Future<String> downloadModel(
    String modelId, {
    AsrDownloadSource source = AsrDownloadSource.huggingFace,
    void Function(AsrModelDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    downloadedModelIds.add(modelId);
    return '/tmp/asr-models/$modelId';
  }
}

/// 记录引擎初始化次数的离线 ASR 引擎。
class _RecordingAsrEngine implements OfflineAsrEngine {
  int initializeCalls = 0;

  @override
  String get name => 'recording';

  @override
  bool get isReady => initializeCalls > 0;

  @override
  AsrModelInfo? get currentModel => null;

  @override
  Future<void> initialize(AsrModelConfig config) async {
    initializeCalls += 1;
  }

  @override
  Future<AsrResult> transcribe(String wavPath) async =>
      const AsrResult(text: '', inferenceTime: Duration.zero);

  @override
  Future<List<AsrSegment>> transcribeSegments(
    String wavPath, {
    void Function(double progress)? onProgress,
  }) async => const [];

  @override
  Future<void> dispose() async {}
}

class _DelayedAsrModelManager extends _FakeAsrModelManager {
  _DelayedAsrModelManager() : super(downloaded: false, localSizeBytes: 99);

  final downloadCompleter = Completer<String>();
  CancelToken? downloadCancelToken;

  @override
  Future<String> downloadModel(
    String modelId, {
    AsrDownloadSource source = AsrDownloadSource.huggingFace,
    void Function(AsrModelDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) {
    downloadCancelToken = cancelToken;
    return downloadCompleter.future;
  }
}

class _BurstProgressAsrModelManager extends _FakeAsrModelManager {
  _BurstProgressAsrModelManager() : super(downloaded: false, localSizeBytes: 0);

  @override
  Future<String> downloadModel(
    String modelId, {
    AsrDownloadSource source = AsrDownloadSource.huggingFace,
    void Function(AsrModelDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    const callbackCount = 10000;
    for (var i = 1; i <= callbackCount; i++) {
      onProgress?.call(
        AsrModelDownloadProgress(
          status: AsrModelDownloadStatus.downloading,
          progress: i / callbackCount,
        ),
      );
    }
    throw StateError('simulated download failure after progress burst');
  }
}

void main() {
  const recommendedModel = AsrModelInfo(
    id: 'whisper-base-en-int8',
    displayName: 'Whisper Base.en',
    type: AsrModelType.whisper,
  );

  test('推荐模型默认保持 Base，不依赖 availableModels 顺序', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final model = container.read(recommendedAsrModelProvider);

    expect(model.id, 'whisper-base-en-int8');
    expect(model.displayName, 'Whisper Base (English)');
  });

  test('下载源完全由系统地区决定，历史手选偏好不再生效', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();

    final global = offlineAsrSettingsStateFromPrefs(
      prefs: prefs,
      recommendedModel: recommendedModel,
      defaultBackend: AsrBackend.offline,
      isChinaUser: false,
    );
    expect(global.downloadSource, AsrDownloadSource.huggingFace);

    final china = offlineAsrSettingsStateFromPrefs(
      prefs: prefs,
      recommendedModel: recommendedModel,
      defaultBackend: AsrBackend.offline,
      isChinaUser: true,
    );
    expect(china.downloadSource, AsrDownloadSource.huggingFaceMirror);

    // 旧版本残留的手选值被忽略：仍按地区解析。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'offline_asr_download_source': AsrDownloadSource.huggingFace.name,
    });
    final legacy = offlineAsrSettingsStateFromPrefs(
      prefs: await SharedPreferences.getInstance(),
      recommendedModel: recommendedModel,
      defaultBackend: AsrBackend.offline,
      isChinaUser: true,
    );
    expect(legacy.downloadSource, AsrDownloadSource.huggingFaceMirror);
  });

  test('旧完成标记不再恢复 downloaded，避免与安装清单漂移', () async {
    SharedPreferences.setMockInitialValues({
      'offline_asr_downloaded_whisper-base-en-int8': true,
    });
    final prefs = await SharedPreferences.getInstance();
    final state = offlineAsrSettingsStateFromPrefs(
      prefs: prefs,
      recommendedModel: recommendedModel,
      defaultBackend: AsrBackend.offline,
      isChinaUser: false,
    );

    expect(state.enabled, isTrue);
    expect(state.downloadStatus, AsrModelDownloadStatus.notDownloaded);
    expect(state.localSizeBytes, 0);
  });

  test('无完成标记保持 notDownloaded', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final state = offlineAsrSettingsStateFromPrefs(
      prefs: prefs,
      recommendedModel: recommendedModel,
      defaultBackend: AsrBackend.offline,
      isChinaUser: false,
    );

    expect(state.downloadStatus, AsrModelDownloadStatus.notDownloaded);
  });

  test('高频下载进度只发布有限 UI 状态更新', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final manager = _BurstProgressAsrModelManager();
    final initialState = OfflineAsrSettingsState(
      backend: AsrBackend.offline,
      recommendedModel: recommendedModel,
    );
    final container = ProviderContainer(
      overrides: [
        asrModelManagerProvider.overrideWithValue(manager),
        offlineAsrSettingsProvider.overrideWith(
          () => _TestOfflineAsrSettingsNotifier(initialState),
        ),
      ],
    );
    addTearDown(container.dispose);

    final publishedProgress = <double>[];
    final subscription = container.listen(offlineAsrSettingsProvider, (
      previous,
      next,
    ) {
      if (next.downloadStatus == AsrModelDownloadStatus.downloading &&
          next.downloadProgress > 0) {
        publishedProgress.add(next.downloadProgress);
      }
    });
    addTearDown(subscription.close);

    await container.read(offlineAsrSettingsProvider.notifier).retryDownload();

    expect(publishedProgress, hasLength(lessThan(100)));
    expect(publishedProgress.last, 1);
    expect(
      container.read(offlineAsrSettingsProvider).downloadStatus,
      AsrModelDownloadStatus.failed,
    );
  });

  test('无效持久化模型选择回退到推荐模型', () async {
    SharedPreferences.setMockInitialValues({
      'offline_asr_selected_model_id': 'removed-model',
    });
    final prefs = await SharedPreferences.getInstance();
    final state = offlineAsrSettingsStateFromPrefs(
      prefs: prefs,
      recommendedModel: recommendedModel,
      defaultBackend: AsrBackend.offline,
      isChinaUser: false,
    );

    expect(state.selectedModel.id, recommendedModel.id);
  });

  test('持久化后端和模型选择同步恢复', () async {
    SharedPreferences.setMockInitialValues({
      'offline_asr_backend': AsrBackend.offline.name,
      'offline_asr_selected_model_id': 'whisper-base-en-int8',
      'offline_asr_downloaded_whisper-base-en-int8': true,
    });
    final prefs = await SharedPreferences.getInstance();
    final state = offlineAsrSettingsStateFromPrefs(
      prefs: prefs,
      recommendedModel: recommendedModel,
      defaultBackend: AsrBackend.platform,
      isChinaUser: false,
    );

    expect(state.backend, AsrBackend.offline);
    expect(state.selectedModel.id, recommendedModel.id);
    expect(state.downloadStatus, AsrModelDownloadStatus.notDownloaded);
  });

  test('主动取消下载会清理残留并回到未下载态，不显示失败', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final manager = _FakeAsrModelManager(downloaded: false, localSizeBytes: 99);
    final modelId = recommendedModel.id;
    final initialState = OfflineAsrSettingsState(
      backend: AsrBackend.offline,
      recommendedModel: recommendedModel,
      modelStates: {
        modelId: const AsrModelState(
          downloadStatus: AsrModelDownloadStatus.downloading,
          downloadProgress: 0.4,
          localSizeBytes: 99,
          downloadError: DownloadFailureKind.network,
        ),
      },
    );
    final container = ProviderContainer(
      overrides: [
        asrModelManagerProvider.overrideWithValue(manager),
        offlineAsrSettingsProvider.overrideWith(
          () => _TestOfflineAsrSettingsNotifier(initialState),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(offlineAsrSettingsProvider.notifier).cancelDownload();

    final state = container.read(offlineAsrSettingsProvider);
    expect(manager.deleteModelCallCount, 1);
    expect(manager.discardPartialDownloadCallCount, 1);
    expect(state.downloadStatus, AsrModelDownloadStatus.notDownloaded);
    expect(state.downloadProgress, 0);
    expect(state.localSizeBytes, 0);
    expect(state.downloadError, isNull);
    expect(prefs.getBool('offline_asr_downloaded_$modelId'), isNull);
  });

  group('资源库下载', () {
    const otherModelId = 'whisper-tiny-en-int8';

    ProviderContainer containerWith({
      required AsrBackend backend,
      required _SuccessfulDownloadAsrModelManager manager,
      required _RecordingAsrEngine engine,
    }) {
      final container = ProviderContainer(
        overrides: [
          asrModelManagerProvider.overrideWithValue(manager),
          offlineAsrEngineProvider.overrideWithValue(engine),
          offlineAsrSettingsProvider.overrideWith(
            () => _TestOfflineAsrSettingsNotifier(
              OfflineAsrSettingsState(
                backend: backend,
                recommendedModel: recommendedModel,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('系统识别下从资源库下载当前档位不初始化引擎，也不切换后端', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final manager = _SuccessfulDownloadAsrModelManager();
      final engine = _RecordingAsrEngine();
      final container = containerWith(
        backend: AsrBackend.platform,
        manager: manager,
        engine: engine,
      );

      await container
          .read(offlineAsrSettingsProvider.notifier)
          .downloadModel(recommendedModel.id);

      final state = container.read(offlineAsrSettingsProvider);
      expect(state.backend, AsrBackend.platform);
      expect(state.selectedModel.id, recommendedModel.id);
      expect(engine.initializeCalls, 0);
      expect(manager.downloadedModelIds, [recommendedModel.id]);
      expect(
        state.modelStateOf(recommendedModel.id).downloadStatus,
        AsrModelDownloadStatus.downloaded,
      );
    });

    test('本机后端下载非跟读档位后不加载离线引擎', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final manager = _SuccessfulDownloadAsrModelManager();
      final engine = _RecordingAsrEngine();
      final container = containerWith(
        backend: AsrBackend.offline,
        manager: manager,
        engine: engine,
      );

      await container
          .read(offlineAsrSettingsProvider.notifier)
          .downloadModel(otherModelId);

      expect(engine.initializeCalls, 0);
      expect(
        container
            .read(offlineAsrSettingsProvider)
            .modelStateOf(otherModelId)
            .isReady,
        isTrue,
      );
    });

    test('下载跟读当前档位且后端为本机时初始化离线引擎', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final manager = _SuccessfulDownloadAsrModelManager();
      final engine = _RecordingAsrEngine();
      final container = containerWith(
        backend: AsrBackend.offline,
        manager: manager,
        engine: engine,
      );

      await container
          .read(offlineAsrSettingsProvider.notifier)
          .downloadModel(recommendedModel.id);

      expect(engine.initializeCalls, 1);
      expect(container.read(offlineAsrSettingsProvider).engineReady, isTrue);
    });
  });

  test('取消后立即重置 UI，底层写入报存储异常仍不显示重试', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final manager = _DelayedAsrModelManager();
    final initialState = OfflineAsrSettingsState(
      backend: AsrBackend.offline,
      recommendedModel: recommendedModel,
    );
    final container = ProviderContainer(
      overrides: [
        asrModelManagerProvider.overrideWithValue(manager),
        offlineAsrSettingsProvider.overrideWith(
          () => _TestOfflineAsrSettingsNotifier(initialState),
        ),
      ],
    );
    addTearDown(container.dispose);

    final download = container
        .read(offlineAsrSettingsProvider.notifier)
        .retryDownload();
    await Future<void>.delayed(Duration.zero);
    expect(manager.downloadCancelToken, isNotNull);

    final cancel = container
        .read(offlineAsrSettingsProvider.notifier)
        .cancelDownload();
    await Future<void>.delayed(Duration.zero);

    final immediateState = container.read(offlineAsrSettingsProvider);
    expect(immediateState.downloadStatus, AsrModelDownloadStatus.notDownloaded);
    expect(immediateState.downloadProgress, 0);
    expect(immediateState.localSizeBytes, 0);
    expect(immediateState.downloadError, isNull);

    manager.downloadCompleter.completeError(
      const ReliableDownloadException(
        'directory removed during cancellation',
        kind: ReliableDownloadFailure.storage,
      ),
    );
    await cancel;
    await download;

    final state = container.read(offlineAsrSettingsProvider);
    expect(manager.discardPartialDownloadCallCount, 1);
    expect(state.downloadStatus, AsrModelDownloadStatus.notDownloaded);
    expect(state.downloadError, isNull);
    expect(state.localSizeBytes, 0);
  });
}
