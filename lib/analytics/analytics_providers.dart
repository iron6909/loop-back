/// 分析系统 Riverpod Provider 注册
///
/// 参考 [appDatabaseProvider] 的模式：在 `main()` 中提前初始化，
/// Provider 同步暴露。业务代码通过 `ref.read(analyticsServiceProvider)`
/// 获取 [AnalyticsService] 实例。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'analytics_channel.dart';
import 'analytics_service.dart';
import 'channels/log_only_channel.dart';
import 'channels/posthog_channel.dart';
import 'consent_manager.dart';
import '../services/app_logger.dart';

/// 分析服务 Provider。
///
/// 生产环境必须由根 [ProviderScope] 在 `runApp()` 前 override 为已初始化的
/// 最终实例。这样 Riverpod 首次缓存的对象不会在后台初始化完成后被替换。
final analyticsServiceProvider = Provider<AnalyticsService>((ref) {
  throw StateError(
    'analyticsServiceProvider must be overridden at app startup',
  );
});

/// 初始化分析服务
///
/// 通道选择策略：
/// - Debug 模式 → LogOnly
/// - Release 模式 → PostHog（全平台，不依赖 GMS，中国大陆可用）
/// - PostHog 未配置时 → LogOnly（需传入 POSTHOG_API_KEY dart-define）
///
/// Firebase/友盟通道保留备用，当前不启用。
Future<AnalyticsService> initAnalyticsService(
  SharedPreferences prefs, {
  AnalyticsChannel Function()? channelFactory,
}) async {
  final consent = ConsentManager(prefs);
  final channel = (channelFactory ?? _createChannel)();

  // 匿名阶段不做 identify，让 PostHog SDK 自己维护匿名 distinct id。
  // 本地匿名 UUID 会在其异步准备完成后单独注册为 super property，不能阻塞 SDK
  // 就绪或首帧。
  await channel.initialize();

  return AnalyticsService(channel: channel, consent: consent);
}

/// 初始化最终 analytics service；SDK 失败只降级埋点，绝不阻断应用启动。
Future<AnalyticsService> initializeAnalyticsWithFallback(
  SharedPreferences prefs, {
  AnalyticsChannel Function()? channelFactory,
}) async {
  try {
    return await initAnalyticsService(prefs, channelFactory: channelFactory);
  } catch (error, stackTrace) {
    AppLogger.log(
      'Analytics',
      'PostHog initialization failed; using LogOnly: $error',
    );
    AppLogger.log('Analytics', stackTrace.toString());
    final fallback = LogOnlyChannel();
    await fallback.initialize();
    return AnalyticsService(channel: fallback, consent: ConsentManager(prefs));
  }
}

/// 根据配置选择分析通道
///
/// 当前策略：PostHog 全平台统一上报。
AnalyticsChannel _createChannel() {
  if (kDebugMode) return LogOnlyChannel();
  if (PostHogChannel.isConfigured) return PostHogChannel();
  // PostHog 未配置（缺少 POSTHOG_API_KEY dart-define）时降级到日志
  return LogOnlyChannel();
}
