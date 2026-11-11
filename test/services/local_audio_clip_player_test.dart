import 'dart:async';

import 'package:loop_back/models/word_highlight_binding.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/services/pronunciation/local_audio_clip_player.dart';

class _FakeBackend implements AudioClipPlayerBackend {
  bool completeOnOpen = false;
  String? errorOnOpen;
  final completedController = StreamController<void>.broadcast();
  final errorController = StreamController<String>.broadcast();
  final positionController = StreamController<Duration>.broadcast();
  final firstOpen = Completer<void>();
  final opened = <String>[];
  final openedStarts = <Duration>[];
  Duration currentPosition = Duration.zero;
  int stops = 0;

  @override
  Stream<void> get completed => completedController.stream;
  @override
  Stream<String> get errors => errorController.stream;
  @override
  Stream<Duration> get positions => positionController.stream;
  @override
  Duration get position => currentPosition;
  @override
  Future<void> open(String filePath, {Duration start = Duration.zero}) async {
    opened.add(filePath);
    if (!firstOpen.isCompleted) firstOpen.complete();
    openedStarts.add(start);
    currentPosition = start;
    if (completeOnOpen) completedController.add(null);
    if (errorOnOpen case final message?) errorController.add(message);
  }

  @override
  Future<void> stop() async => stops++;
  @override
  Future<void> dispose() async {
    await completedController.close();
    await errorController.close();
    await positionController.close();
  }
}

void main() {
  test('playFile waits for completion and reuses one backend', () async {
    final backend = _FakeBackend();
    final player = LocalAudioClipPlayer(backend: backend);
    final result = player.playFile('/audio/read.opus');
    expect(
      player.wordHighlightPlaybackStatus,
      WordHighlightPlaybackStatus.playing,
    );
    await Future<void>.delayed(Duration.zero);
    expect(backend.opened, ['/audio/read.opus']);
    backend.completedController.add(null);
    expect(await result, AudioPlaybackResult.completed);
    expect(
      player.wordHighlightPlaybackStatus,
      WordHighlightPlaybackStatus.completed,
    );
    expect(backend.stops, 1);
    await player.dispose();
  });

  test('backend error returns failed for TTS fallback', () async {
    final backend = _FakeBackend();
    final player = LocalAudioClipPlayer(backend: backend);
    final result = player.playFile('/audio/broken.opus');
    await Future<void>.delayed(Duration.zero);
    backend.errorController.add('decode failed');
    expect(await result, AudioPlaybackResult.failed);
    await player.dispose();
  });

  test('captures completion emitted immediately by open', () async {
    final backend = _FakeBackend()..completeOnOpen = true;
    final player = LocalAudioClipPlayer(backend: backend);

    expect(
      await player.playFile('/audio/short.opus'),
      AudioPlaybackResult.completed,
    );
    await player.dispose();
  });

  test('captures error emitted immediately by open', () async {
    final backend = _FakeBackend()..errorOnOpen = 'decode failed';
    final player = LocalAudioClipPlayer(backend: backend);

    expect(
      await player.playFile('/audio/broken.opus'),
      AudioPlaybackResult.failed,
    );
    await player.dispose();
  });

  test('无位置流订阅者时不监听后端位置事件', () async {
    final backend = _FakeBackend();
    final player = LocalAudioClipPlayer(backend: backend);
    final playback = player.playFile('/audio/read.opus');
    await backend.firstOpen.future;

    expect(backend.positionController.hasListener, isFalse);

    backend.completedController.add(null);
    expect(await playback, AudioPlaybackResult.completed);
    await player.dispose();
  });

  test('playRangeFile starts at range start and stops at range end', () async {
    final backend = _FakeBackend();
    final player = LocalAudioClipPlayer(backend: backend);
    final result = player.playRangeFile(
      '/audio/source.m4a',
      start: const Duration(seconds: 3),
      end: const Duration(seconds: 5),
    );
    await Future<void>.delayed(Duration.zero);
    expect(backend.openedStarts, [const Duration(seconds: 3)]);
    backend.currentPosition = const Duration(seconds: 5);
    backend.positionController.add(backend.currentPosition);
    expect(await result, AudioPlaybackResult.completed);
    expect(backend.stops, 2);
    await player.dispose();
  });

  test('位置流在后端首次创建前订阅也能收到播放位置', () async {
    final backend = _FakeBackend();
    final player = LocalAudioClipPlayer(backend: backend);
    final positions = <Duration>[];
    final subscription = player.positionStream.listen(positions.add);
    final playback = player.playRangeFile(
      '/audio/source.m4a',
      start: const Duration(seconds: 3),
      end: const Duration(seconds: 5),
    );
    await Future<void>.delayed(Duration.zero);

    backend.currentPosition = const Duration(milliseconds: 3400);
    backend.positionController.add(backend.currentPosition);
    await Future<void>.delayed(Duration.zero);

    expect(positions, [const Duration(milliseconds: 3400)]);
    expect(player.currentPosition, const Duration(milliseconds: 3400));

    await player.stop();
    expect(await playback, AudioPlaybackResult.cancelled);
    await subscription.cancel();
    await player.dispose();
  });

  test('new playback immediately cancels an active range', () async {
    final backend = _FakeBackend();
    final player = LocalAudioClipPlayer(backend: backend);
    final range = player.playRangeFile(
      '/audio/source.m4a',
      start: Duration.zero,
      end: const Duration(seconds: 5),
    );
    await Future<void>.delayed(Duration.zero);
    final file = player.playFile('/audio/word.opus');
    expect(await range, AudioPlaybackResult.cancelled);
    await Future<void>.delayed(Duration.zero);
    backend.completedController.add(null);
    expect(await file, AudioPlaybackResult.completed);
    await player.dispose();
  });

  test(
    'publishes caller key while active and clears it when stopped',
    () async {
      final backend = _FakeBackend();
      final player = LocalAudioClipPlayer(backend: backend);
      final states = <LocalAudioClipPlaybackState>[];
      final subscription = player.states.listen(states.add);

      final playback = player.playFile(
        '/audio/read.opus',
        playbackKey: 'source:1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(player.state.playingKey, 'source:1');

      await player.stop();

      expect(await playback, AudioPlaybackResult.cancelled);
      expect(
        player.wordHighlightPlaybackStatus,
        WordHighlightPlaybackStatus.paused,
      );
      expect(player.state.playingKey, isNull);
      expect(states.map((state) => state.playingKey), ['source:1', null]);
      await subscription.cancel();
      await player.dispose();
    },
  );

  test(
    'range captures immediate completion and rejects invalid bounds',
    () async {
      final backend = _FakeBackend()..completeOnOpen = true;
      final player = LocalAudioClipPlayer(backend: backend);

      expect(
        await player.playRangeFile(
          '/audio/short.opus',
          start: const Duration(seconds: 1),
          end: const Duration(seconds: 2),
        ),
        AudioPlaybackResult.completed,
      );
      expect(
        await player.playRangeFile(
          '/audio/short.opus',
          start: const Duration(seconds: -1),
          end: const Duration(seconds: 2),
        ),
        AudioPlaybackResult.failed,
      );
      expect(
        await player.playRangeFile(
          '/audio/short.opus',
          start: const Duration(seconds: 2),
          end: const Duration(seconds: 2),
        ),
        AudioPlaybackResult.failed,
      );
      expect(backend.opened, hasLength(1));
      await player.dispose();
    },
  );

  test('stop immediately cancels an active playback', () async {
    final backend = _FakeBackend();
    final player = LocalAudioClipPlayer(backend: backend);
    final playback = player.playFile('/audio/read.opus');
    await Future<void>.delayed(Duration.zero);

    await player.stop();

    expect(await playback, AudioPlaybackResult.cancelled);
    await player.dispose();
  });

  test('dispose immediately cancels an active playback', () async {
    final backend = _FakeBackend();
    final player = LocalAudioClipPlayer(backend: backend);
    final playback = player.playFile('/audio/read.opus');
    await Future<void>.delayed(Duration.zero);

    await player.dispose();

    expect(await playback, AudioPlaybackResult.cancelled);
  });
}
