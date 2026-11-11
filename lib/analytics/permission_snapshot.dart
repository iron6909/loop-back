/// 系统授权状态快照（仅供埋点使用）。
///
/// 一次性查询 3 类系统授权状态（麦克风 / 语音识别 / 通知），
/// 上报到 PostHog（super properties + person properties + 自定义事件）。
/// 不参与业务流程判断；状态值是字符串而非 enum，方便直接序列化。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/speech_practice_models.dart';
import '../services/notification_permission_reporter.dart';
import '../services/speech_practice_platform.dart';
import 'analytics_service.dart';
import 'models/event_names.dart';

/// 3 类系统授权状态的不可变快照。
@immutable
class PermissionSnapshot {
  // ── 状态字符串常量（避免在事件流里出现拼写漂移） ──
  static const String statusGranted = 'granted';
  static const String statusDenied = 'denied';
  static const String statusNotDetermined = 'notDetermined';
  static const String statusRestricted = 'restricted';
  static const String statusUnknown = 'unknown';
  static const String statusNotApplicable = 'not_applicable';

  static const String spKeyLastReported = 'analytics_permission_snapshot_v1';

  final String microphone;
  final String speech;
  final String notification;

  const PermissionSnapshot({
    required this.microphone,
    required this.speech,
    required this.notification,
  });

  /// 转成事件参数 / user property map（key 来自 [EventParams]）。
  Map<String, Object> toEventParams() => {
    EventParams.microphoneStatus: microphone,
    EventParams.speechStatus: speech,
    EventParams.notificationStatus: notification,
  };

  /// 一次性查询 3 类授权状态。
  ///
  /// 任意一类查询失败回退为 [statusUnknown]，不影响其他类。
  /// 测试时通过 [probe] 注入伪造实现，避免触发真实平台插件。
  static Future<PermissionSnapshot> capture(
    SharedPreferences prefs, {
    PermissionProbe? probe,
  }) async {
    final p = probe ?? const DefaultPermissionProbe();

    String mic = statusUnknown;
    String sp = statusUnknown;
    try {
      final r = await p.readSpeechAndMicrophoneStatus();
      mic = r.microphone;
      sp = r.speech;
    } catch (_) {
      // 保持 unknown
    }

    String notif = statusUnknown;
    try {
      notif = await p.readNotificationStatus();
    } catch (_) {
      // 保持 unknown
    }

    return PermissionSnapshot(microphone: mic, speech: sp, notification: notif);
  }
}

/// 把快照三路写入分析系统：super properties + person properties + 自定义事件。
///
/// - super properties 让本地 SDK 之后发的所有事件冻结当时的权限值
/// - person properties 写到 PostHog 用户画像，可按当前授权状态分群
/// - `app_permission_snapshot` 自定义事件作为冷启动锚点
///
/// [AnalyticsService] 已在每个底层方法做了 consent gate + try/catch；
/// 这里只串起来。consent 未同意时三路全部静默丢弃。
extension PermissionSnapshotReporting on AnalyticsService {
  Future<void> reportPermissionSnapshot(
    PermissionSnapshot snapshot,
    SharedPreferences prefs,
  ) async {
    final params = snapshot.toEventParams();
    final fingerprint = [
      snapshot.microphone,
      snapshot.speech,
      snapshot.notification,
    ].join('|');
    if (prefs.getString(PermissionSnapshot.spKeyLastReported) == fingerprint) {
      return;
    }
    await prefs.setString(PermissionSnapshot.spKeyLastReported, fingerprint);
    await registerSuperProperties(params);
    await setUserProperties(
      params.map((key, value) => MapEntry(key, value.toString())),
    );
    await track(Events.appPermissionSnapshot, params);
  }
}

/// 抽象 probe；测试时实现 fake 替代真实平台插件。
abstract class PermissionProbe {
  const PermissionProbe();

  /// 同时返回麦克风 + 语音识别授权状态。
  Future<({String microphone, String speech})> readSpeechAndMicrophoneStatus();

  /// 返回通知授权状态。
  Future<String> readNotificationStatus();
}

/// 默认 probe：调用真实平台插件。
class DefaultPermissionProbe implements PermissionProbe {
  const DefaultPermissionProbe();

  @override
  Future<({String microphone, String speech})>
  readSpeechAndMicrophoneStatus() async {
    final platform = SpeechPracticePlatform.instance;
    if (!platform.isSupported) {
      return (
        microphone: PermissionSnapshot.statusNotApplicable,
        speech: PermissionSnapshot.statusNotApplicable,
      );
    }
    final state = await platform.getPermissionStatus();
    return (
      microphone: _mapSpeechStatus(state.microphone),
      speech: _mapSpeechStatus(state.speech),
    );
  }

  @override
  Future<String> readNotificationStatus() async {
    if (kIsWeb) return PermissionSnapshot.statusNotApplicable;
    final reporter = _resolveReporter();
    if (!reporter.isSupported) return PermissionSnapshot.statusNotApplicable;
    try {
      final status = await reporter.getAuthorizationStatus();
      return _mapAuthorization(status);
    } catch (_) {
      return PermissionSnapshot.statusUnknown;
    }
  }

  static NotificationPermissionReporter _resolveReporter() {
    if (Platform.isMacOS) return MacOSNotificationPermissionReporter();
    if (Platform.isIOS) {
      return IOSNotificationPermissionReporter();
    }
    if (Platform.isAndroid) {
      return AndroidNotificationPermissionReporter(
        FlutterLocalNotificationsPlugin(),
      );
    }
    return const UnsupportedNotificationPermissionReporter();
  }

  static String _mapAuthorization(NotificationAuthorization status) {
    switch (status) {
      case NotificationAuthorization.authorized:
        return PermissionSnapshot.statusGranted;
      case NotificationAuthorization.denied:
        return PermissionSnapshot.statusDenied;
      case NotificationAuthorization.notDetermined:
        return PermissionSnapshot.statusNotDetermined;
      case NotificationAuthorization.restricted:
        return PermissionSnapshot.statusRestricted;
      case NotificationAuthorization.unsupported:
        return PermissionSnapshot.statusNotApplicable;
    }
  }

  static String _mapSpeechStatus(SpeechPracticePermissionStatus s) {
    switch (s) {
      case SpeechPracticePermissionStatus.granted:
        return PermissionSnapshot.statusGranted;
      case SpeechPracticePermissionStatus.denied:
        return PermissionSnapshot.statusDenied;
      case SpeechPracticePermissionStatus.notDetermined:
        return PermissionSnapshot.statusNotDetermined;
      case SpeechPracticePermissionStatus.restricted:
        return PermissionSnapshot.statusRestricted;
    }
  }
}
