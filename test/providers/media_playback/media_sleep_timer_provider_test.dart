import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/models/media_playback_state.dart';
import 'package:loop_back/providers/media_playback/media_playback_provider.dart';
import 'package:loop_back/providers/media_playback/media_sleep_timer_provider.dart';

class _TestMediaPlayback extends MediaPlayback {
  int pauseCount = 0;

  @override
  MediaPlaybackState build() => const MediaPlaybackState();

  @override
  Future<void> pause() async {
    pauseCount++;
  }
}

void main() {
  test('到点只暂停视频播放并清空定时状态', () {
    fakeAsync((async) {
      final playback = _TestMediaPlayback();
      final container = ProviderContainer(
        overrides: [mediaPlaybackProvider.overrideWith(() => playback)],
      );
      addTearDown(container.dispose);
      final timer = container.read(mediaSleepTimerProvider.notifier);

      timer.start(const Duration(minutes: 5));
      async.elapse(const Duration(minutes: 5, seconds: 1));

      expect(playback.pauseCount, 1);
      expect(container.read(mediaSleepTimerProvider).isActive, isFalse);
    });
  });

  test('重设后旧定时器不能暂停新的媒体播放', () {
    fakeAsync((async) {
      final playback = _TestMediaPlayback();
      final container = ProviderContainer(
        overrides: [mediaPlaybackProvider.overrideWith(() => playback)],
      );
      addTearDown(container.dispose);
      final timer = container.read(mediaSleepTimerProvider.notifier);

      timer.start(const Duration(minutes: 5));
      async.elapse(const Duration(minutes: 4));
      timer.start(const Duration(minutes: 10));
      async.elapse(const Duration(minutes: 2));

      expect(playback.pauseCount, 0);
      async.elapse(const Duration(minutes: 8, seconds: 1));
      expect(playback.pauseCount, 1);
    });
  });
}
