import 'package:loop_back/services/media_kit_player_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  test('视频随心听进入后台时不自动暂停播放器', () {
    final backend = MediaKitPlayerBackend(
      player: Player(platformPlayer: _TestPlatformPlayer()),
    );

    final video = backend.buildVideoView(viewportSize: const Size(390, 844));
    final pausesInBackground = switch (video) {
      Video(:final pauseUponEnteringBackgroundMode) =>
        pauseUponEnteringBackgroundMode,
      _ => true,
    };

    expect(pausesInBackground, isFalse);
  });
}

class _TestPlatformPlayer extends PlatformPlayer {
  _TestPlatformPlayer() : super(configuration: const PlayerConfiguration());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
