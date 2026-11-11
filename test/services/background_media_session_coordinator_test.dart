import 'dart:async';

import 'package:loop_back/services/background_audio_handler.dart';
import 'package:loop_back/services/media_session_router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('系统媒体会话失败时仍保留前台 handler/router', () async {
    var attempts = 0;
    final coordinator = BackgroundMediaSessionCoordinator(
      prepareHandler: (_) async {},
      initializeSystemSession: (_) async {
        attempts += 1;
        throw StateError('audio service unavailable');
      },
    );

    await expectLater(
      coordinator.initializeSystemSession(),
      throwsA(isA<StateError>()),
    );

    expect(attempts, 1);
    expect(coordinator.isSystemSessionReady, isFalse);
    expect(coordinator.handler, isA<LoopBackAudioHandler>());
    expect(coordinator.router, isA<MediaSessionRouter>());
  });

  test('下一次初始化可静默重试并恢复系统媒体会话', () async {
    var attempts = 0;
    final coordinator = BackgroundMediaSessionCoordinator(
      prepareHandler: (_) async {},
      initializeSystemSession: (_) async {
        attempts += 1;
        if (attempts == 1) throw StateError('temporary failure');
      },
    );

    await expectLater(
      coordinator.initializeSystemSession(),
      throwsA(isA<StateError>()),
    );
    await coordinator.initializeSystemSession();

    expect(attempts, 2);
    expect(coordinator.isSystemSessionReady, isTrue);
  });

  test('并发初始化共享同一个系统媒体会话尝试', () async {
    final gate = Completer<void>();
    var attempts = 0;
    final coordinator = BackgroundMediaSessionCoordinator(
      prepareHandler: (_) async {},
      initializeSystemSession: (_) async {
        attempts += 1;
        await gate.future;
      },
    );

    final first = coordinator.initializeSystemSession();
    final second = coordinator.initializeSystemSession();
    gate.complete();
    await Future.wait<void>([first, second]);

    expect(attempts, 1);
    expect(coordinator.isSystemSessionReady, isTrue);
  });
}
