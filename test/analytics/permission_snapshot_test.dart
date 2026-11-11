import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:loop_back/analytics/analytics_channel.dart';
import 'package:loop_back/analytics/analytics_service.dart';
import 'package:loop_back/analytics/consent_manager.dart';
import 'package:loop_back/analytics/models/event_names.dart';
import 'package:loop_back/analytics/permission_snapshot.dart';

/// 不出错的伪 probe：返回固定值。
class _FakeProbe implements PermissionProbe {
  final String microphone;
  final String speech;
  final String notification;

  const _FakeProbe({
    required this.microphone,
    required this.speech,
    required this.notification,
  });

  @override
  Future<({String microphone, String speech})>
  readSpeechAndMicrophoneStatus() async =>
      (microphone: microphone, speech: speech);

  @override
  Future<String> readNotificationStatus() async => notification;
}

/// readSpeechAndMicrophoneStatus 抛错的 probe，用于验证容错。
class _ThrowingSpeechProbe implements PermissionProbe {
  final String notification;
  const _ThrowingSpeechProbe({required this.notification});

  @override
  Future<({String microphone, String speech})>
  readSpeechAndMicrophoneStatus() async {
    throw Exception('boom');
  }

  @override
  Future<String> readNotificationStatus() async => notification;
}

/// 记录所有调用的 channel，给 reportPermissionSnapshot 测试用。
class _RecordingChannel implements AnalyticsChannel {
  final List<({String name, Map<String, Object>? params})> events = [];
  final List<({String name, String? value})> userProperties = [];
  final List<Map<String, Object>> superPropertiesCalls = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> logEvent(String name, Map<String, Object>? parameters) async {
    events.add((name: name, params: parameters));
  }

  @override
  Future<void> setUserId(String? id) async {}

  @override
  Future<void> setUserProperty(String name, String? value) async {
    userProperties.add((name: name, value: value));
  }

  @override
  Future<void> setUserProperties(Map<String, String?> properties) async {
    for (final entry in properties.entries) {
      await setUserProperty(entry.key, entry.value);
    }
  }

  @override
  Future<void> registerSuperProperties(Map<String, Object> properties) async {
    superPropertiesCalls.add(properties);
  }

  @override
  Future<void> unregisterSuperProperty(String name) async {}
}

/// readNotificationStatus 抛错的 probe，用于验证容错。
class _ThrowingNotificationProbe implements PermissionProbe {
  final String microphone;
  final String speech;
  const _ThrowingNotificationProbe({
    required this.microphone,
    required this.speech,
  });

  @override
  Future<({String microphone, String speech})>
  readSpeechAndMicrophoneStatus() async =>
      (microphone: microphone, speech: speech);

  @override
  Future<String> readNotificationStatus() async {
    throw Exception('boom');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PermissionSnapshot.toEventParams', () {
    test('字段映射到 EventParams 常量 key', () {
      const snap = PermissionSnapshot(
        microphone: PermissionSnapshot.statusGranted,
        speech: PermissionSnapshot.statusDenied,
        notification: PermissionSnapshot.statusNotDetermined,
      );

      final params = snap.toEventParams();
      expect(params, {
        EventParams.microphoneStatus: PermissionSnapshot.statusGranted,
        EventParams.speechStatus: PermissionSnapshot.statusDenied,
        EventParams.notificationStatus: PermissionSnapshot.statusNotDetermined,
      });
    });

    test('所有 value 都是 String，符合 PostHog property 类型约束', () {
      const snap = PermissionSnapshot(
        microphone: PermissionSnapshot.statusUnknown,
        speech: PermissionSnapshot.statusUnknown,
        notification: PermissionSnapshot.statusUnknown,
      );
      final params = snap.toEventParams();
      for (final v in params.values) {
        expect(v, isA<String>());
      }
    });
  });

  group('PermissionSnapshot.capture (注入 probe)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('happy path：probe 返回值原样填充', () async {
      final prefs = await SharedPreferences.getInstance();
      final snap = await PermissionSnapshot.capture(
        prefs,
        probe: const _FakeProbe(
          microphone: PermissionSnapshot.statusGranted,
          speech: PermissionSnapshot.statusGranted,
          notification: PermissionSnapshot.statusDenied,
        ),
      );
      expect(snap.microphone, PermissionSnapshot.statusGranted);
      expect(snap.speech, PermissionSnapshot.statusGranted);
      expect(snap.notification, PermissionSnapshot.statusDenied);
    });

    test('mic/speech probe 抛错时，两项均回退为 unknown，notification 不受影响', () async {
      final prefs = await SharedPreferences.getInstance();
      final snap = await PermissionSnapshot.capture(
        prefs,
        probe: const _ThrowingSpeechProbe(
          notification: PermissionSnapshot.statusGranted,
        ),
      );
      expect(snap.microphone, PermissionSnapshot.statusUnknown);
      expect(snap.speech, PermissionSnapshot.statusUnknown);
      expect(snap.notification, PermissionSnapshot.statusGranted);
    });

    test('notification probe 抛错时，仅 notification 回退为 unknown', () async {
      final prefs = await SharedPreferences.getInstance();
      final snap = await PermissionSnapshot.capture(
        prefs,
        probe: const _ThrowingNotificationProbe(
          microphone: PermissionSnapshot.statusGranted,
          speech: PermissionSnapshot.statusDenied,
        ),
      );
      expect(snap.microphone, PermissionSnapshot.statusGranted);
      expect(snap.speech, PermissionSnapshot.statusDenied);
      expect(snap.notification, PermissionSnapshot.statusUnknown);
    });
  });

  group('PermissionSnapshotReporting.reportPermissionSnapshot', () {
    late _RecordingChannel channel;
    late SharedPreferences prefs;
    late ConsentManager consent;
    late AnalyticsService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      channel = _RecordingChannel();
      consent = ConsentManager(prefs);
      service = AnalyticsService(channel: channel, consent: consent);
    });

    test('三路写入：super properties + 3 个 person property + 1 个事件', () async {
      const snapshot = PermissionSnapshot(
        microphone: PermissionSnapshot.statusGranted,
        speech: PermissionSnapshot.statusGranted,
        notification: PermissionSnapshot.statusDenied,
      );

      await service.reportPermissionSnapshot(snapshot, prefs);

      // super properties 一次性写入 3 类
      expect(channel.superPropertiesCalls, hasLength(1));
      expect(channel.superPropertiesCalls.first, snapshot.toEventParams());

      // 3 个 person property（每类一次）
      expect(channel.userProperties, hasLength(3));
      final byKey = {for (final e in channel.userProperties) e.name: e.value};
      expect(byKey[EventParams.microphoneStatus], snapshot.microphone);
      expect(byKey[EventParams.speechStatus], snapshot.speech);
      expect(byKey[EventParams.notificationStatus], snapshot.notification);

      // 1 个 app_permission_snapshot 事件，参数和 snapshot 一致
      expect(channel.events, hasLength(1));
      expect(channel.events.first.name, Events.appPermissionSnapshot);
      expect(channel.events.first.params, snapshot.toEventParams());
    });

    test('用户未同意时三路全部静默丢弃', () async {
      await consent.revokeConsent();

      const snapshot = PermissionSnapshot(
        microphone: PermissionSnapshot.statusGranted,
        speech: PermissionSnapshot.statusGranted,
        notification: PermissionSnapshot.statusGranted,
      );
      await service.reportPermissionSnapshot(snapshot, prefs);

      expect(channel.superPropertiesCalls, isEmpty);
      expect(channel.userProperties, isEmpty);
      expect(channel.events, isEmpty);
    });

    test('权限未变化时不重复上报', () async {
      const snapshot = PermissionSnapshot(
        microphone: PermissionSnapshot.statusGranted,
        speech: PermissionSnapshot.statusGranted,
        notification: PermissionSnapshot.statusDenied,
      );
      await service.reportPermissionSnapshot(snapshot, prefs);
      await service.reportPermissionSnapshot(snapshot, prefs);
      expect(channel.events, hasLength(1));
      expect(channel.superPropertiesCalls, hasLength(1));
      expect(channel.userProperties, hasLength(3));
    });
  });

  group('PermissionSnapshot 状态字符串常量', () {
    test('值不重复，符合命名约定', () {
      const all = [
        PermissionSnapshot.statusGranted,
        PermissionSnapshot.statusDenied,
        PermissionSnapshot.statusNotDetermined,
        PermissionSnapshot.statusRestricted,
        PermissionSnapshot.statusUnknown,
        PermissionSnapshot.statusNotApplicable,
      ];
      expect(all.toSet().length, all.length);
      for (final s in all) {
        expect(s, isNotEmpty);
      }
    });
  });
}
