import 'dart:async';

import 'package:loop_back/services/app_logger.dart';
import 'package:loop_back/services/media_kit_duration_probe.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDurationProbePlayer implements DurationProbePlayer {
  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final Completer<void> opened = Completer<void>();
  Duration currentDuration = Duration.zero;
  bool disposed = false;
  bool openPausedCalled = false;

  @override
  Duration get duration => currentDuration;

  @override
  Stream<Duration> get durationStream => _durationController.stream;

  @override
  Stream<String> get errorStream => _errorController.stream;

  @override
  Future<void> openPaused(String filePath) async {
    openPausedCalled = true;
    if (!opened.isCompleted) opened.complete();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _durationController.close();
    await _errorController.close();
  }

  void emitDuration(Duration value) => _durationController.add(value);

  void emitError(String value) => _errorController.add(value);
}

void main() {
  group('MediaKitDurationProbe', () {
    test('等待文件打开后的正时长事件，且不播放并释放播放器', () async {
      final player = _FakeDurationProbePlayer();
      var initialized = false;
      final probe = MediaKitDurationProbe(
        playerFactory: () => player,
        ensureInitialized: () => initialized = true,
      );

      final result = probe.read('/local/video.mkv');
      await player.opened.future;
      player.emitDuration(const Duration(seconds: 83));

      expect(await result, const Duration(seconds: 83));
      expect(initialized, isTrue);
      expect(player.openPausedCalled, isTrue);
      expect(player.disposed, isTrue);
    });

    test('媒体错误返回 null 并释放播放器', () async {
      AppLogger.instance.clear();
      final player = _FakeDurationProbePlayer();
      final probe = MediaKitDurationProbe(
        playerFactory: () => player,
        ensureInitialized: () {},
      );

      final result = probe.read('/local/broken.mkv');
      await player.opened.future;
      player.emitError('native error');

      expect(await result, isNull);
      expect(player.disposed, isTrue);
    });

    test('错误流自身报错时返回 null 并释放播放器', () async {
      AppLogger.instance.clear();
      final player = _FakeDurationProbePlayer();
      final probe = MediaKitDurationProbe(
        playerFactory: () => player,
        ensureInitialized: () {},
      );

      final result = probe.read('/local/stream-error.mkv');
      await player.opened.future;
      player._errorController.addError(StateError('stream failed'));

      expect(await result, isNull);
      expect(player.disposed, isTrue);
      expect(
        AppLogger.instance.entries.any(
          (entry) => entry.message.contains(
            'event=media_duration_probe_failed trace=none phase=media_error',
          ),
        ),
        isTrue,
      );
    });

    test('没有时长事件时超时返回 null 并释放播放器', () async {
      final player = _FakeDurationProbePlayer();
      final probe = MediaKitDurationProbe(
        timeout: Duration.zero,
        playerFactory: () => player,
        ensureInitialized: () {},
      );

      expect(await probe.read('/local/no-duration.mkv'), isNull);
      expect(player.openPausedCalled, isTrue);
      expect(player.disposed, isTrue);
    });
  });
}
