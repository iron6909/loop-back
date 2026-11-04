/// 客户端平台与分发渠道的统一身份协议。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

/// 对外分发渠道协议，只允许商店与直装三类正式值。
enum ClientDistribution {
  play('play'),
  appStore('app_store'),
  direct('direct');

  const ClientDistribution(this.headerValue);

  final String headerValue;
}

/// 编译期注入的原始分发渠道。
const rawDistributionChannel = String.fromEnvironment('DISTRIBUTION_CHANNEL');

/// 解析分发渠道，并兼容旧构建值 `apk` / `desktop`。
///
/// 未注入或非法值返回 null，由评分入口与设备诊断使用各自的默认行为。
@visibleForTesting
ClientDistribution? parseClientDistribution(String rawValue) {
  switch (rawValue.trim().toLowerCase()) {
    case 'play':
      return ClientDistribution.play;
    case 'app_store':
      return ClientDistribution.appStore;
    case 'direct':
    case 'apk':
    case 'desktop':
      return ClientDistribution.direct;
    default:
      return null;
  }
}

/// 当前构建的规范化分发渠道。
ClientDistribution? get clientDistribution =>
    parseClientDistribution(rawDistributionChannel);

/// 当前平台名：`ios` / `macos` / `android` / `windows`，未知平台返回空串。
String clientPlatformName() {
  if (kIsWeb) return '';
  if (Platform.isIOS) return 'ios';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isAndroid) return 'android';
  if (Platform.isWindows) return 'windows';
  return '';
}
