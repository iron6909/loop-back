/// Android 更新原生桥接。
///
/// 只在 Android 平台调用：读取安装来源，用于区分应用商店安装和 APK 直装。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

import 'app_logger.dart';

/// Android 更新桥接接口，便于单测注入 fake。
abstract interface class AndroidUpdateBridge {
  Future<String?> installerPackageName();
}

/// MethodChannel 实现。
class MethodChannelAndroidUpdateBridge implements AndroidUpdateBridge {
  const MethodChannelAndroidUpdateBridge();

  @visibleForTesting
  static const channel = MethodChannel('top.loop-back/app_update');

  @override
  Future<String?> installerPackageName() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      return await channel.invokeMethod<String>('getInstallerPackageName');
    } catch (e) {
      AppLogger.log('AppUpdateBridge', 'installer source failed: $e');
      return null;
    }
  }
}
