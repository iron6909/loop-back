import 'package:loop_back/analytics/analytics_service.dart';
import 'package:loop_back/analytics/models/event_names.dart';
import 'package:loop_back/services/notification_permission_reporter.dart';
import 'package:loop_back/services/notification_permission_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockAnalyticsService extends Mock implements AnalyticsService {}

class MockNotificationPermissionReporter extends Mock
    implements NotificationPermissionReporter {}

class FakeTrigger implements NotificationPromptTrigger {
  int triggerCount = 0;
  bool _showing = false;

  @override
  bool get isShowing => _showing;

  @override
  void trigger() {
    if (_showing) return;
    _showing = true;
    triggerCount++;
  }

  @override
  void onDialogClosed() {
    _showing = false;
  }
}

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
  });

  late MockAnalyticsService analytics;
  late MockNotificationPermissionReporter reporter;
  late FakeTrigger trigger;
  late SharedPreferences prefs;

  Future<NotificationPermissionService> buildService({
    required NotificationAuthorization authStatus,
    bool requestResult = true,
    DateTime? now,
    bool isAndroid = false,
  }) async {
    when(
      () => reporter.getAuthorizationStatus(),
    ).thenAnswer((_) async => authStatus);
    when(
      () => reporter.requestAuthorization(),
    ).thenAnswer((_) async => requestResult);
    when(() => reporter.openSettings()).thenAnswer((_) async {});

    final service = NotificationPermissionService(
      prefs: prefs,
      analytics: analytics,
      trigger: trigger,
      reporter: reporter,
      isAndroid: isAndroid,
    );
    if (now != null) {
      service.now = () => now;
    }
    return service;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    analytics = MockAnalyticsService();
    reporter = MockNotificationPermissionReporter();
    trigger = FakeTrigger();

    when(() => analytics.track(any(), any())).thenAnswer((_) async {});
  });

  group('maybeTriggerPrompt 决策（基于 SP authorization_status）', () {
    test('SP authorization_status 已存在 → skip(already_decided)', () async {
      await prefs.setBool('notification_authorization_status', true);
      final service = await buildService(
        authStatus: NotificationAuthorization.authorized,
      );

      await service.maybeTriggerPrompt();

      expect(trigger.triggerCount, 0);
      verify(
        () => analytics.track(Events.notificationPromptSkipped, {
          EventParams.reason: 'already_decided',
        }),
      ).called(1);
    });

    test('SP 不存在 + 无冷却 → trigger fired', () async {
      final service = await buildService(
        authStatus: NotificationAuthorization.notDetermined,
      );

      await service.maybeTriggerPrompt();

      expect(trigger.triggerCount, 1);
      verifyNever(
        () => analytics.track(Events.notificationPromptSkipped, any()),
      );
    });

    test('SP 不存在 + dismiss < 14 天 → skip(cooldown)', () async {
      final now = DateTime(2026, 5, 22, 12, 0);
      final lastShown = now.subtract(const Duration(days: 7));
      await prefs.setString('notification_prompt_last_action', 'dismiss');
      await prefs.setInt(
        'notification_prompt_last_shown_at',
        lastShown.millisecondsSinceEpoch,
      );
      final service = await buildService(
        authStatus: NotificationAuthorization.notDetermined,
        now: now,
      );

      await service.maybeTriggerPrompt();

      expect(trigger.triggerCount, 0);
      verify(
        () => analytics.track(Events.notificationPromptSkipped, {
          EventParams.reason: 'cooldown',
        }),
      ).called(1);
    });

    test('SP 不存在 + dismiss > 14 天 → 重新 trigger fired', () async {
      final now = DateTime(2026, 5, 22, 12, 0);
      final lastShown = now.subtract(const Duration(days: 15));
      await prefs.setString('notification_prompt_last_action', 'dismiss');
      await prefs.setInt(
        'notification_prompt_last_shown_at',
        lastShown.millisecondsSinceEpoch,
      );
      final service = await buildService(
        authStatus: NotificationAuthorization.notDetermined,
        now: now,
      );

      await service.maybeTriggerPrompt();

      expect(trigger.triggerCount, 1);
    });

    test('SP 不存在 + grant < 14 天 → skip(cooldown)', () async {
      final now = DateTime(2026, 5, 22, 12, 0);
      final lastShown = now.subtract(const Duration(days: 3));
      await prefs.setString('notification_prompt_last_action', 'grant');
      await prefs.setInt(
        'notification_prompt_last_shown_at',
        lastShown.millisecondsSinceEpoch,
      );
      final service = await buildService(
        authStatus: NotificationAuthorization.notDetermined,
        now: now,
      );

      await service.maybeTriggerPrompt();

      expect(trigger.triggerCount, 0);
      verify(
        () => analytics.track(Events.notificationPromptSkipped, {
          EventParams.reason: 'cooldown',
        }),
      ).called(1);
    });

    test(
      'Android: authorization_status=false 但未点过应用内弹窗 → trigger fired',
      () async {
        await prefs.setBool('notification_authorization_status', false);
        final service = await buildService(
          authStatus: NotificationAuthorization.denied,
          isAndroid: true,
        );

        await service.maybeTriggerPrompt();

        expect(trigger.triggerCount, 1);
        verifyNever(
          () => analytics.track(Events.notificationPromptSkipped, any()),
        );
      },
    );

    test(
      'Android: authorization_status=false 且已点过开启 → skip(already_decided)',
      () async {
        await prefs.setBool('notification_authorization_status', false);
        await prefs.setString('notification_prompt_last_action', 'grant');
        await prefs.setInt(
          'notification_prompt_last_shown_at',
          DateTime(2026, 5, 1).millisecondsSinceEpoch,
        );
        final service = await buildService(
          authStatus: NotificationAuthorization.denied,
          isAndroid: true,
        );

        await service.maybeTriggerPrompt();

        expect(trigger.triggerCount, 0);
        verify(
          () => analytics.track(Events.notificationPromptSkipped, {
            EventParams.reason: 'already_decided',
          }),
        ).called(1);
      },
    );

    test('Android: dismiss 未过 14 天 → skip(cooldown)', () async {
      final now = DateTime(2026, 5, 22, 12, 0);
      await prefs.setBool('notification_authorization_status', false);
      await prefs.setString('notification_prompt_last_action', 'dismiss');
      await prefs.setInt(
        'notification_prompt_last_shown_at',
        now.subtract(const Duration(days: 7)).millisecondsSinceEpoch,
      );
      final service = await buildService(
        authStatus: NotificationAuthorization.denied,
        now: now,
        isAndroid: true,
      );

      await service.maybeTriggerPrompt();

      expect(trigger.triggerCount, 0);
      verify(
        () => analytics.track(Events.notificationPromptSkipped, {
          EventParams.reason: 'cooldown',
        }),
      ).called(1);
    });

    test('Android: dismiss 超过 14 天 → 重新 trigger fired', () async {
      final now = DateTime(2026, 5, 22, 12, 0);
      await prefs.setBool('notification_authorization_status', false);
      await prefs.setString('notification_prompt_last_action', 'dismiss');
      await prefs.setInt(
        'notification_prompt_last_shown_at',
        now.subtract(const Duration(days: 15)).millisecondsSinceEpoch,
      );
      final service = await buildService(
        authStatus: NotificationAuthorization.denied,
        now: now,
        isAndroid: true,
      );

      await service.maybeTriggerPrompt();

      expect(trigger.triggerCount, 1);
    });
  });

  group('getCurrentState 派生状态机', () {
    test('authorized → state granted', () async {
      final service = await buildService(
        authStatus: NotificationAuthorization.authorized,
      );
      final s = await service.getCurrentState();
      expect(s, NotificationPermissionState.granted);
    });

    test('notDetermined → state canRequest', () async {
      final service = await buildService(
        authStatus: NotificationAuthorization.notDetermined,
      );
      final s = await service.getCurrentState();
      expect(s, NotificationPermissionState.canRequest);
    });

    test('denied → state blocked', () async {
      final service = await buildService(
        authStatus: NotificationAuthorization.denied,
      );
      final s = await service.getCurrentState();
      expect(s, NotificationPermissionState.blocked);
    });

    test('restricted → state blocked', () async {
      final service = await buildService(
        authStatus: NotificationAuthorization.restricted,
      );
      final s = await service.getCurrentState();
      expect(s, NotificationPermissionState.blocked);
    });

    test('unsupported → state canRequest', () async {
      final service = await buildService(
        authStatus: NotificationAuthorization.unsupported,
      );
      final s = await service.getCurrentState();
      expect(s, NotificationPermissionState.canRequest);
    });
  });

  group('onUserAcceptedPrompt / onUserDismissedPrompt', () {
    test('onUserAccepted granted → SP authorization_status=true', () async {
      final service = await buildService(
        authStatus: NotificationAuthorization.notDetermined,
        requestResult: true,
      );

      final granted = await service.onUserAcceptedPrompt();

      expect(granted, isTrue);
      verify(
        () => analytics.track(Events.notificationPromptResult, {
          EventParams.action: 'grant',
        }),
      ).called(1);
      verify(
        () => analytics.track(Events.notificationSystemResult, {
          EventParams.status: 'granted',
        }),
      ).called(1);
      expect(
        prefs.getString('notification_prompt_last_action'),
        equals('grant'),
      );
      expect(prefs.getInt('notification_prompt_last_shown_at'), isNotNull);
      expect(prefs.getBool('notification_authorization_status'), isTrue);
      verify(() => reporter.requestAuthorization()).called(1);
    });

    test('onUserAccepted denied + authStatus=denied → SP=false', () async {
      final service = await buildService(
        authStatus: NotificationAuthorization.denied,
        requestResult: false,
      );

      final granted = await service.onUserAcceptedPrompt();

      expect(granted, isFalse);
      verify(
        () => analytics.track(Events.notificationSystemResult, {
          EventParams.status: 'denied',
        }),
      ).called(1);
      expect(
        prefs.getBool('notification_authorization_status'),
        isFalse,
        reason: '用户明确拒绝 → 写 false',
      );
    });

    test('onUserAccepted denied + authStatus=restricted → SP=false', () async {
      final service = await buildService(
        authStatus: NotificationAuthorization.restricted,
        requestResult: false,
      );

      await service.onUserAcceptedPrompt();

      expect(
        prefs.getBool('notification_authorization_status'),
        isFalse,
        reason: 'restricted 也算明确决策，写 false',
      );
    });

    test(
      'onUserAccepted denied + authStatus=notDetermined → SP 不写（iOS 手势 dismiss）',
      () async {
        // granted=false + still notDetermined → 无法确认用户决策，不写 SP
        final service = await buildService(
          authStatus: NotificationAuthorization.notDetermined,
          requestResult: false,
        );

        await service.onUserAcceptedPrompt();

        expect(
          prefs.getBool('notification_authorization_status'),
          isNull,
          reason: '手势 dismiss 未真正决策，SP 不写',
        );
      },
    );

    test('onUserDismissed 埋点 + 持久化 dismiss, 不调系统 API', () async {
      final service = await buildService(
        authStatus: NotificationAuthorization.notDetermined,
      );

      await service.onUserDismissedPrompt();

      verify(
        () => analytics.track(Events.notificationPromptResult, {
          EventParams.action: 'dismiss',
        }),
      ).called(1);
      expect(
        prefs.getString('notification_prompt_last_action'),
        equals('dismiss'),
      );
      verifyNever(() => reporter.requestAuthorization());
      expect(
        prefs.getBool('notification_authorization_status'),
        isNull,
        reason: 'dismiss 不调系统 API，不写 authorization_status',
      );
    });
  });
}
