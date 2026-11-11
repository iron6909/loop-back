/// 系统 Region 的读取入口与中国区判定。
///
/// 地区结论仅用于分析侧标记，不再关联任何远程服务端点。
library;

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote_config/remote_config.dart';
import '../../services/app_logger.dart';
import 'user_region.dart';
import 'user_region_bootstrapper.dart';
import 'user_region_override.dart';

/// 系统 Region 读取 seam；测试可注入固定国家码。
final userRegionDeviceCountryCodeProvider = Provider<String? Function()>(
  (ref) =>
      () => PlatformDispatcher.instance.locale.countryCode,
);

/// 首帧后按系统地区和本机覆盖值固定地区结论，不访问任何远程服务。
final userRegionBootstrapProvider = FutureProvider<UserRegionBootstrapResult>((
  ref,
) async {
  final readCountryCode = ref.watch(userRegionDeviceCountryCodeProvider);
  await WidgetsBinding.instance.endOfFrame;
  final override = await _readOverride(ref);
  final forcedRegion = override.forcedRegion;
  final isChinaUser = forcedRegion == null
      ? _readSystemRegionIsChina(readCountryCode)
      : forcedRegion == AppRegion.china;
  return UserRegionBootstrapResult(
    isChinaUser: isChinaUser,
    source: forcedRegion == null
        ? UserRegionDecisionSource.systemFallback
        : UserRegionDecisionSource.developerOverride,
    remoteConfig: RemoteConfig.defaults,
  );
});

/// 地区在本进程内固定；解析期间暂用系统 Region。
final isChinaUserProvider = Provider<bool>((ref) {
  final result = ref.watch(userRegionBootstrapProvider).valueOrNull;
  return result?.isChinaUser ??
      _readSystemRegionIsChina(ref.watch(userRegionDeviceCountryCodeProvider));
});

/// 读取开发者地区覆盖；读取失败时按自动判定处理，不阻断启动。
Future<UserRegionOverride> _readOverride(Ref ref) async {
  try {
    return await ref.read(userRegionOverrideStoreProvider).load();
  } catch (error) {
    AppLogger.log('UserRegion', 'developer override read failed: $error');
    return UserRegionOverride.auto;
  }
}

bool _readSystemRegionIsChina(String? Function() readCountryCode) {
  try {
    return isChinaSystemRegion(readCountryCode());
  } catch (error, stackTrace) {
    AppLogger.log('UserRegion', 'system Region read failed: $error');
    AppLogger.log('UserRegion', stackTrace.toString());
    return false;
  }
}
