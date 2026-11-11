import 'dart:async';

import 'package:loop_back/services/media_fullscreen_service.dart';
import 'package:loop_back/services/window_fullscreen_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('移动端横向视频进入全屏时锁横屏并在退出时恢复系统状态', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    final service = MediaFullscreenService();
    final entered = service.changes.first;

    final accepted = await service.enter(isLandscapeVideo: true);

    expect(accepted, isTrue);
    expect(await entered, isTrue);
    expect(
      calls.map((call) => call.method),
      containsAll([
        'SystemChrome.setPreferredOrientations',
        'SystemChrome.setEnabledSystemUIMode',
      ]),
    );

    final exited = service.changes.first;
    await service.exit();

    expect(await exited, isFalse);
    expect(
      calls.map((call) => call.method),
      contains('SystemChrome.setEnabledSystemUIOverlays'),
    );
    await service.dispose();
  });

  test('移动端竖向视频全屏不强制横屏', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    final service = MediaFullscreenService();

    await service.enter(isLandscapeVideo: false);

    expect(
      calls.where(
        (call) => call.method == 'SystemChrome.setPreferredOrientations',
      ),
      isEmpty,
    );
    await service.exit();
    await service.dispose();
  });

  test('未进入全屏时退出不会改写全局系统栏状态', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    final service = MediaFullscreenService();

    await service.exit();

    expect(calls, isEmpty);
    await service.dispose();
  });

  test('macOS 窗口绿色按钮全屏不展开视频，视频按钮仍可展开', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final window = _FakeWindowFullscreenController();
    final service = MediaFullscreenService(windowService: window);
    final states = <bool>[];
    final subscription = service.changes.listen(states.add);

    window.emit(true);
    await Future<void>.delayed(Duration.zero);
    expect(states, isEmpty);

    await service.enter(isLandscapeVideo: true);
    expect(states, [true]);
    expect(window.requests, [true]);

    window.emit(false);
    await Future<void>.delayed(Duration.zero);
    expect(states, [true, false]);

    await subscription.cancel();
    await service.dispose();
  });
}

class _FakeWindowFullscreenController implements WindowFullscreenController {
  final _changes = StreamController<bool>.broadcast(sync: true);
  final requests = <bool>[];

  @override
  Stream<bool> get changes => _changes.stream;

  void emit(bool fullscreen) => _changes.add(fullscreen);

  @override
  Future<bool> setFullscreen(bool fullscreen) async {
    requests.add(fullscreen);
    return true;
  }

  @override
  Future<void> dispose() => _changes.close();
}
