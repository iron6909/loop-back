/// 功能配置 Riverpod 入口。
///
/// 后端 Config API 停用后，配置恒为本机默认值；保留 controller 外壳与
/// `refreshIfStale` 等既有调用点，避免业务侧再感知配置来源。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'remote_config.dart';
import 'remote_config_dependencies.dart';
import 'remote_config_service.dart';

export 'remote_config_dependencies.dart'
    show initialRemoteConfigProvider, remoteConfigServiceProvider;

final remoteConfigProvider =
    StateNotifierProvider<RemoteConfigController, RemoteConfig>((ref) {
      return RemoteConfigController(
        readService: () => ref.read(remoteConfigServiceProvider),
        initialConfig: ref.watch(initialRemoteConfigProvider),
      );
    });

final remoteFeatureEnabledProvider = Provider.family<bool, RemoteFeature>((
  ref,
  feature,
) {
  return ref.watch(remoteConfigProvider).isEnabled(feature);
});

final remoteTranscriptionLimitsProvider = Provider<RemoteTranscriptionLimits>((
  ref,
) {
  return ref.watch(remoteConfigProvider).transcriptionLimits;
});

/// 配置控制器外壳：不再有定时刷新与网络请求，调用即无操作。
class RemoteConfigController extends StateNotifier<RemoteConfig> {
  RemoteConfigController({
    required RemoteConfigService Function() readService,
    required RemoteConfig initialConfig,
    DateTime Function()? now,
  }) : _readService = readService,
       super(initialConfig);

  // 保持构造签名兼容既存调用方与测试替身。
  // ignore: unused_field
  final RemoteConfigService Function() _readService;

  void startPeriodicRefresh({
    bool forceFirst = false,
    bool skipInitialRequest = false,
  }) {}

  void adoptStartupConfig(RemoteConfig config) {
    state = config;
  }

  void stopPeriodicRefresh() {}

  Future<void> refreshIfStale({bool force = false}) async {}
}
