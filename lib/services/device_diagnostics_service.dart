/// 设备诊断信息服务。
///
/// 用于开发者日志页进入时写入一次设备与运行环境快照，便于用户分享日志后
/// 直接看到机型、系统版本、App 版本等排障关键信息。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../config/client_distribution.dart';

/// 读取并格式化设备诊断信息。
class DeviceDiagnosticsService {
  const DeviceDiagnosticsService({MethodChannel methodChannel = channel})
    : _channel = methodChannel;

  /// 原生设备信息通道。
  @visibleForTesting
  static const MethodChannel channel = MethodChannel(
    'top.loop-back/device_info',
  );

  final MethodChannel _channel;

  /// 构建单行诊断日志。
  ///
  /// 原生通道失败时仍返回可用的 Dart 侧环境信息，并带上失败原因，避免诊断
  /// 日志本身阻断日志页分享。
  Future<String> buildLogLine(BuildContext context) async {
    final dartInfo = await _dartInfo(context);
    final nativeInfo = <String, String>{};
    String? nativeError;

    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'getDeviceInfo',
      );
      if (result != null) {
        for (final entry in result.entries) {
          final value = entry.value;
          if (value == null) continue;
          nativeInfo[entry.key] = _stringify(value);
        }
      }
    } catch (e) {
      nativeError = e.toString();
    }

    final fields = <String, String>{
      ...dartInfo,
      ...nativeInfo,
      if (nativeError != null) 'nativeError': nativeError,
    };
    return fields.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Future<Map<String, String>> _dartInfo(BuildContext context) async {
    final mediaQuery = MediaQuery.maybeOf(context);
    final locale =
        Localizations.maybeLocaleOf(context) ??
        ui.PlatformDispatcher.instance.locale;
    final distribution = clientDistribution;
    final packageInfo = await _safePackageInfo();
    final screen = mediaQuery == null
        ? null
        : '${mediaQuery.size.width.toStringAsFixed(0)}x'
              '${mediaQuery.size.height.toStringAsFixed(0)}@'
              '${mediaQuery.devicePixelRatio.toStringAsFixed(2)}';

    return {
      if (packageInfo != null)
        'app': '${packageInfo.version}+${packageInfo.buildNumber}',
      'platform': clientPlatformName().isEmpty
          ? 'unknown'
          : clientPlatformName(),
      if (distribution != null) 'distribution': distribution.headerValue,
      'locale': locale.toLanguageTag(),
      'timezone': DateTime.now().timeZoneName,
      if (screen != null) 'screen': screen,
    };
  }

  Future<PackageInfo?> _safePackageInfo() async {
    try {
      return await PackageInfo.fromPlatform();
    } catch (_) {
      return null;
    }
  }

  String _stringify(Object value) {
    if (value is Iterable<Object?>) {
      return value.whereType<Object>().map(_stringify).join(',');
    }
    return value.toString();
  }
}
