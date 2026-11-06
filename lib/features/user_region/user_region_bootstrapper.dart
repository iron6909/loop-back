/// 启动地区结论及其来源。
///
/// 地区判定不再依赖后端 Config API：只读系统 Region 与本机开发者覆盖值，
/// 因此 [UserRegionDecisionSource.remoteConfig] 仅保留给历史调用方兼容。
library;

import '../remote_config/remote_config.dart';

/// 地区解析的来源，供启动诊断与 UI 状态共享。
enum UserRegionDecisionSource { remoteConfig, systemFallback, developerOverride }

/// 本进程启动时采用的地区。
class UserRegionBootstrapResult {
  const UserRegionBootstrapResult({
    required this.isChinaUser,
    required this.source,
    required this.remoteConfig,
  });

  final bool isChinaUser;
  final UserRegionDecisionSource source;

  /// 兼容字段：功能开关固定为本地默认值，调用方不应再据此区分。
  final RemoteConfig remoteConfig;
}
