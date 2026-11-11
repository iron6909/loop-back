/// 单文件试听控制器的状态流转测试。
///
/// 覆盖：播放期间为 true、自然结束回落 false、stop 立即回落、重复播放不叠加、
/// 起播失败不卡在播放态、旧播放不覆盖新状态、注入的 service 不被误释放，
/// 以及返回值能区分「播到结束」与「失败或被打断」。
library;

import 'dart:async';

import 'package:loop_back/services/audio_playback_service.dart';
import 'package:loop_back/services/audio_preview_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// 不触碰平台的播放替身，由测试决定每次播放何时结束。
class _FakePlaybackService extends AudioPlaybackService {
  final List<String> playedFiles = [];
  int stopCalls = 0;
  int disposeCalls = 0;
  Object? playError;
  Completer<void>? _completer;

  @override
  Future<void> play(String filePath) {
    playedFiles.add(filePath);
    final error = playError;
    if (error != null) return Future<void>.error(error);
    _completer = Completer<void>();
    return _completer!.future;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    _finish();
  }

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
    _finish();
  }

  /// 模拟播放自然结束。
  void finishPlayback() => _finish();

  void _finish() {
    final completer = _completer;
    _completer = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }
}

void main() {
  late _FakePlaybackService service;
  late AudioPreviewController controller;

  setUp(() {
    service = _FakePlaybackService();
    controller = AudioPreviewController(service: service);
  });

  test('播放期间为 true，自然结束后回落 false 并返回 true', () async {
    final playing = controller.play('/tmp/a.m4a');

    expect(controller.isPlaying, isTrue);
    service.finishPlayback();
    expect(await playing, isTrue);
    expect(controller.isPlaying, isFalse);
    expect(service.playedFiles, ['/tmp/a.m4a']);
  });

  test('stop 立即回落 false 并停到 service', () async {
    final playing = controller.play('/tmp/a.m4a');
    expect(controller.isPlaying, isTrue);

    await controller.stop();
    expect(controller.isPlaying, isFalse);
    expect(service.stopCalls, 1);
    // 被打断不算播完，调用方据此不该打「播放结束」日志。
    expect(await playing, isFalse);
  });

  test('已在播放时再次 play 不叠加，且返回 false', () async {
    final playing = controller.play('/tmp/a.m4a');

    expect(await controller.play('/tmp/b.m4a'), isFalse);
    expect(service.playedFiles, ['/tmp/a.m4a']);
    service.finishPlayback();
    expect(await playing, isTrue);
  });

  test('起播失败返回 false，不抛异常也不卡在播放态', () async {
    service.playError = StateError('boom');

    expect(await controller.play('/tmp/a.m4a'), isFalse);
    expect(controller.isPlaying, isFalse);
  });

  test('被 stop 取代的旧播放结束后不覆盖新播放的状态', () async {
    final first = controller.play('/tmp/a.m4a');
    await controller.stop();
    // stop 已让第一次播放的 Future 完成，新播放随后开始。
    final second = controller.play('/tmp/b.m4a');
    await first;

    expect(controller.isPlaying, isTrue);
    service.finishPlayback();
    await second;
    expect(controller.isPlaying, isFalse);
  });

  test('toggle 在播则停、未播则播', () async {
    final playing = controller.toggle('/tmp/a.m4a');
    expect(controller.isPlaying, isTrue);

    await controller.toggle('/tmp/a.m4a');
    expect(controller.isPlaying, isFalse);
    expect(service.stopCalls, 1);
    await playing;
  });

  test('注入的 service 生命周期归注入方，controller 不释放它', () async {
    await controller.dispose();

    expect(service.disposeCalls, 0);
  });

  test('自建 service 时由 controller 负责释放', () async {
    // 自建路径下无法注入替身，只验证重复 dispose 不抛错。
    final owning = AudioPreviewController();
    await owning.dispose();
    await owning.dispose();
  });
}
