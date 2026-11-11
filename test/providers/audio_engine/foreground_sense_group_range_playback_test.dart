import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/providers/audio_engine/foreground_audio_engine_provider.dart';
import 'package:loop_back/providers/audio_engine/foreground_sense_group_range_playback.dart';

void main() {
  group('ForegroundSenseGroupRangePlayback', () {
    test(
      'cancel without an owned range session leaves main audio active',
      () async {
        final engine = _ControlledForegroundAudioEngine();
        final rangePlayback = _createPlayback(engine);
        final mainSessionId = engine.newSession();

        await rangePlayback.cancel();

        expect(engine.pauseCount, 0);
        expect(engine.isActiveSession(mainSessionId), true);
      },
    );

    test('late cancel cannot pause a newer main playback session', () async {
      final engine = _ControlledForegroundAudioEngine();
      final rangePlayback = _createPlayback(engine);
      final playFuture = rangePlayback.play(
        'audio-1',
        Duration.zero,
        const Duration(seconds: 1),
      );
      await engine.rangeSessionStarted.future;

      final mainSessionId = engine.newSession();
      await rangePlayback.cancel();

      expect(engine.pauseCount, 0);
      expect(engine.isActiveSession(mainSessionId), true);
      engine.completeRangePlayback();
      await playFuture;
    });

    test('cancel pauses the active range session it owns', () async {
      final engine = _ControlledForegroundAudioEngine();
      final rangePlayback = _createPlayback(engine);
      final playFuture = rangePlayback.play(
        'audio-1',
        Duration.zero,
        const Duration(seconds: 1),
      );
      final rangeSessionId = await engine.rangeSessionStarted.future;

      await rangePlayback.cancel();

      expect(engine.pauseCount, 1);
      expect(engine.isActiveSession(rangeSessionId), false);
      engine.completeRangePlayback();
      await playFuture;
    });

    test(
      'cancelled loading request does not start a stale range playback',
      () async {
        final engine = _ControlledForegroundAudioEngine(
          delayBeforeSession: true,
        );
        final rangePlayback = _createPlayback(engine);
        final playFuture = rangePlayback.play(
          'audio-1',
          Duration.zero,
          const Duration(seconds: 1),
        );
        await engine.rangeRequestStarted.future;

        await rangePlayback.cancel();
        engine.completeLoading();
        await playFuture;

        expect(engine.rangeStartCount, 0);
        expect(engine.pauseCount, 0);
      },
    );
  });
}

ForegroundSenseGroupRangePlayback _createPlayback(
  _ControlledForegroundAudioEngine engine,
) => ForegroundSenseGroupRangePlayback(engine: engine, playbackSpeed: () => 1);

class _ControlledForegroundAudioEngine extends ForegroundAudioEngine {
  _ControlledForegroundAudioEngine({this.delayBeforeSession = false});

  final bool delayBeforeSession;
  final Completer<void> rangeRequestStarted = Completer<void>();
  final Completer<int> rangeSessionStarted = Completer<int>();
  final Completer<void> _loading = Completer<void>();
  final Completer<void> _rangePlayback = Completer<void>();

  int _sessionId = 0;
  int pauseCount = 0;
  int rangeStartCount = 0;

  @override
  int newSession() => ++_sessionId;

  @override
  bool isActiveSession(int id) => id == _sessionId;

  @override
  Future<void> pause() async {
    pauseCount++;
    newSession();
  }

  @override
  Future<void> playRangeForAudio(
    String audioItemId,
    Duration start,
    Duration end, {
    required double speed,
    bool Function()? isRequestActive,
    void Function(int sessionId)? onSessionStarted,
  }) async {
    if (!rangeRequestStarted.isCompleted) rangeRequestStarted.complete();
    if (delayBeforeSession) await _loading.future;
    if (isRequestActive != null && !isRequestActive()) return;

    final sessionId = newSession();
    onSessionStarted?.call(sessionId);
    if (!rangeSessionStarted.isCompleted) {
      rangeSessionStarted.complete(sessionId);
    }
    rangeStartCount++;
    await _rangePlayback.future;
  }

  void completeLoading() => _loading.complete();

  void completeRangePlayback() => _rangePlayback.complete();
}
