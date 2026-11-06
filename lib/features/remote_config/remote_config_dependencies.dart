/// 功能配置的 Riverpod 依赖。
///
/// 全部为本机默认值；不再依赖 SharedPreferences、地区路由或版本信息。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'remote_config.dart';
import 'remote_config_service.dart';

/// 启动期可用同步读取的本地默认配置。
final initialRemoteConfigProvider = Provider<RemoteConfig>(
  (ref) => RemoteConfig.defaults,
);

/// 配置服务：无缓存、无网络。
final remoteConfigServiceProvider = Provider<RemoteConfigService>(
  (ref) => const RemoteConfigService(),
);
