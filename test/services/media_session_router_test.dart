import 'package:audio_service/audio_service.dart';
import 'package:loop_back/services/media_session_router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('activate/deactivate 只允许当前占用者交还会话', () async {
    final echo = _RecordingHandler('echo');
    final videoA = _RecordingHandler('video-a');
    final videoB = _RecordingHandler('video-b');
    final router = MediaSessionRouter(defaultHandler: echo);

    await router.play();
    expect(echo.playCalls, 1);

    router.activate(videoA);
    expect(router.isRouted, isTrue);
    await router.pause();
    expect(videoA.pauseCalls, 1);
    expect(echo.pauseCalls, 0);

    router.activate(videoB);
    router.deactivate(videoA);
    await router.seek(const Duration(seconds: 3));
    expect(videoB.seekCalls, [const Duration(seconds: 3)]);

    router.deactivate(videoB);
    expect(router.isRouted, isFalse);
    await router.stop();
    expect(echo.stopCalls, 1);
  });
}

class _RecordingHandler extends BaseAudioHandler {
  _RecordingHandler(this.name);

  final String name;
  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  final seekCalls = <Duration>[];

  @override
  Future<void> play() async {
    playCalls += 1;
  }

  @override
  Future<void> pause() async {
    pauseCalls += 1;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls.add(position);
  }
}
