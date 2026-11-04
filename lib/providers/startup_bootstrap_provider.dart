/// 标准化应用启动编排。
///
/// 本地数据初始化使用 Riverpod 的 [AsyncNotifier] 作为唯一状态来源：首帧后
/// 执行关键本地任务，失败状态供首页降级提示、日志和重试使用，不阻断业务导航壳。
library;

import 'dart:async';
import 'dart:io';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analytics/analytics_providers.dart';
import '../analytics/analytics_service.dart';
import '../analytics/permission_snapshot.dart';
import '../database/app_database.dart';
import '../database/providers.dart';
import '../features/onboarding_survey/providers/onboarding_survey_provider.dart'
    show sharedPreferencesProvider;
import '../features/user_region/user_region_providers.dart';
import '../firebase_options.dart';
import '../services/app_logger.dart';
import '../services/asr/asr_model_manager.dart';
import '../services/background_audio_handler.dart';
import '../services/bundled_example_installer.dart';
import '../services/network_permission_trigger.dart';
import '../services/speech_practice_platform.dart';
import '../services/startup_trace.dart';
import '../services/runtime_endpoint_router.dart';
import '../services/temp_cleanup_service.dart';
import '../services/tts/tts_cache_store.dart';
import '../utils/app_data_dir.dart';

/// 本次启动的可降级问题；不包含本地数据致命错误。
class StartupIssue {
  const StartupIssue({
    required this.step,
    required this.error,
    required this.stackTrace,
  });

  final String step;
  final Object error;
  final StackTrace stackTrace;
}

/// 已完成的启动报告。issues 非空表示应用以降级模式继续运行。
class StartupReport {
  const StartupReport(this.issues);

  final List<StartupIssue> issues;

  bool get isDegraded => issues.isNotEmpty;
}

/// 演示库模式由 main 在真实进程中覆盖；测试默认生产库语义。
final startupDemoModeProvider = Provider<bool>((ref) => false);

/// 将启动所需副作用集中于可替换对象，避免 widget 与 main() 各自维护状态。
final startupBootstrapperProvider = Provider<StartupBootstrapper>((ref) {
  return DefaultStartupBootstrapper(
    database: ref.read(appDatabaseProvider),
    prefs: ref.read(sharedPreferencesProvider),
    isDemoMode: ref.read(startupDemoModeProvider),
    analyticsService: ref.read(analyticsServiceProvider),
  );
});

/// 本地数据初始化状态。首次构建先等待首帧，再运行关键本地初始化。
final localStartupProvider =
    AsyncNotifierProvider<LocalStartupController, StartupReport>(
      LocalStartupController.new,
    );

/// 非核心 SDK 初始化依赖本地数据成功，但其自身失败不会令 Future 悬挂。
final thirdPartyStartupProvider = FutureProvider<StartupReport>((ref) async {
  final localStartup = ref.watch(localStartupProvider.future);
  final userRegionBootstrap = ref.watch(userRegionBootstrapProvider.future);
  await Future.wait([localStartup, userRegionBootstrap]);
  return ref.read(startupBootstrapperProvider).initializeThirdParty();
});

class LocalStartupController extends AsyncNotifier<StartupReport> {
  Future<void>? _inFlight;

  @override
  Future<StartupReport> build() async {
    await WidgetsBinding.instance.endOfFrame;
    activeStartupTrace?.mark('flutter_first_frame_rendered');
    return _initialize();
  }

  /// 对本地数据致命错误进行显式重试；同一时刻只允许一个运行实例。
  Future<void> retry() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    state = const AsyncLoading();
    final operation = _runRetry();
    _inFlight = operation;
    return operation;
  }

  Future<void> _runRetry() async {
    try {
      state = await AsyncValue.guard(_initialize);
    } finally {
      _inFlight = null;
    }
  }

  Future<StartupReport> _initialize() {
    final trace = activeStartupTrace;
    if (trace == null) {
      return ref.read(startupBootstrapperProvider).initializeLocal();
    }
    return trace.run(
      'local_startup_bootstrap',
      ref.read(startupBootstrapperProvider).initializeLocal,
    );
  }
}

/// 启动副作用编排契约；测试可替换为确定性实现。
abstract class StartupBootstrapper {
  Future<StartupReport> initializeLocal();

  Future<StartupReport> initializeThirdParty();
}

/// 生产启动副作用编排器。关键本地步骤抛错，可降级步骤收集为报告。
class DefaultStartupBootstrapper implements StartupBootstrapper {
  DefaultStartupBootstrapper({
    required AppDatabase database,
    required SharedPreferences prefs,
    required bool isDemoMode,
    required AnalyticsService analyticsService,
  }) : _database = database,
       _prefs = prefs,
       _isDemoMode = isDemoMode,
       _analyticsService = analyticsService;

  final AppDatabase _database;
  final SharedPreferences _prefs;
  final bool _isDemoMode;
  final AnalyticsService _analyticsService;

  /// 执行本地数据初始化；失败会向上抛出，由首页以降级状态承接。
  @override
  Future<StartupReport> initializeLocal() async {
    final issues = <StartupIssue>[];
    await _configurePersistentLogs(issues);

    // 显式打开数据库，使 schema upgrade 失败进入本地初始化错误状态。
    await _trace('database_open_and_schema_check', () async {
      await _database.customSelect('SELECT 1').get();
    });

    if (!_isDemoMode) {
      await _runBestEffort(
        issues,
        'bundled_examples_install',
        () => BundledExampleInstaller(_database, _prefs).installOnFirstLaunch(),
      );
    }

    activeStartupTrace?.mark(
      issues.isEmpty ? 'local_data_ready' : 'local_data_degraded',
      fields: {'issueCount': issues.length},
    );
    return StartupReport(List<StartupIssue>.unmodifiable(issues));
  }

  /// 执行不会阻断本地学习的 SDK 与维护任务，并保证正常结束。
  @override
  Future<StartupReport> initializeThirdParty() async {
    final issues = <StartupIssue>[];
    await _runBestEffort(
      issues,
      'background_audio_handler_initialize',
      initEchoLoopAudioHandler,
    );

    if (!kIsWeb && Platform.isIOS) {
      activeStartupTrace?.mark(
        'detached_scheduled',
        fields: {'step': 'ios_network_permission_trigger'},
      );
      unawaited(
        NetworkPermissionTrigger.trigger(
          _prefs,
          runtimeEndpointRouter.modelCdnBaseUrl,
        ),
      );
    }

    var firebaseReady = false;
    try {
      await _trace('firebase_initialize', () {
        return Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      });
      firebaseReady = true;
    } catch (error, stackTrace) {
      _recordIssue(issues, 'firebase_initialize', error, stackTrace);
    }
    if (firebaseReady && !kDebugMode && !Platform.isMacOS) {
      await _runBestEffort(issues, 'firebase_analytics_disable', () {
        return FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(false);
      });
    }

    await _runBestEffort(issues, 'permission_snapshot_report', () async {
      final snapshot = await PermissionSnapshot.capture(_prefs);
      await _analyticsService.reportPermissionSnapshot(snapshot, _prefs);
    });

    _scheduleMaintenance();
    activeStartupTrace?.mark(
      'third_party_services_ready',
      fields: {'issueCount': issues.length},
    );
    return StartupReport(List<StartupIssue>.unmodifiable(issues));
  }

  Future<void> _configurePersistentLogs(List<StartupIssue> issues) async {
    try {
      await _trace('app_log_file_sink', () async {
        await AppLogger.configurePersistentOutput(await appLogDirectoryPath());
      });
    } catch (error, stackTrace) {
      _recordIssue(issues, 'app_log_file_sink', error, stackTrace);
    } finally {
      activeStartupTrace?.attachLogger();
    }
  }

  void _scheduleMaintenance() {
    unawaited(cleanupRecordingTempFiles());
    unawaited(cleanupStalePdfExportTemp());
    unawaited(cleanupCommunityDownloadTmp());
    Future<void>.delayed(const Duration(seconds: 8), () async {
      final cache = TtsCacheStore(
        resolveDao: () => _database.ttsCacheDao,
        resolveCacheDir: getApplicationCacheDirectory,
      );
      await cache.cleanup();
    });
    if (!kIsWeb) unawaited(_logRecommendedAsrModel());
  }

  Future<void> _logRecommendedAsrModel() async {
    try {
      final platform = SpeechPracticePlatform.instance;
      final ramBytes = platform.isSupported
          ? await _trace(
              'offline_asr_device_ram_read',
              platform.getDeviceRamBytes,
            )
          : 0;
      final manager = AsrModelManager();
      final recommendedModel = manager.recommendModel(ramBytes: ramBytes);
      manager.dispose();
      AppLogger.log('App', 'ASR recommended model=${recommendedModel.id}');
    } catch (error, stackTrace) {
      AppLogger.log(
        'Startup',
        'offline_asr_recommendation_failed error=$error',
      );
      AppLogger.log('Startup', stackTrace.toString());
    }
  }

  Future<T> _trace<T>(String step, Future<T> Function() operation) {
    final trace = activeStartupTrace;
    return trace == null ? operation() : trace.run(step, operation);
  }

  Future<void> _runBestEffort(
    List<StartupIssue> issues,
    String step,
    Future<void> Function() operation,
  ) async {
    try {
      await _trace(step, operation);
    } catch (error, stackTrace) {
      _recordIssue(issues, step, error, stackTrace);
    }
  }

  void _recordIssue(
    List<StartupIssue> issues,
    String step,
    Object error,
    StackTrace stackTrace,
  ) {
    issues.add(StartupIssue(step: step, error: error, stackTrace: stackTrace));
    AppLogger.log('Startup', '$step failed: $error');
    AppLogger.log('Startup', stackTrace.toString());
  }
}
