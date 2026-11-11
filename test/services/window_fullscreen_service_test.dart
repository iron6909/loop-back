import 'package:loop_back/services/window_fullscreen_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('test/window_fullscreen');

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('macOS setFullscreen 通过平台通道传递目标状态', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });

    final service = WindowFullscreenService(channel: channel);
    final ok = await service.setFullscreen(true);

    expect(ok, isTrue);
    expect(calls.single.method, 'setFullscreen');
    expect(calls.single.arguments, {'fullscreen': true});
    await service.dispose();
  });

  test('原生窗口完成切换后向页面发布真实全屏状态', () async {
    final service = WindowFullscreenService(channel: channel);
    final changed = service.changes.first;

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('fullscreenChanged', true),
          ),
          (_) {},
        );

    expect(await changed, isTrue);
    await service.dispose();
  });
}
