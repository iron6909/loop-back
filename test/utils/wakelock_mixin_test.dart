// WakelockMixin 测试
//
// 验证 mixin 在 initState 时启用屏幕常亮，在 dispose 时关闭。
// 通过覆盖 wakelockPlusPlatformInstance 来 mock 平台调用。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/utils/wakelock_mixin.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// Mock WakelockPlus 平台实现，记录 toggle 调用
class _MockWakelockPlatform extends WakelockPlusPlatformInterface {
  final List<bool> toggleCalls = [];
  bool _enabled = false;

  // 绕过 PlatformInterface.verify 检查
  @override
  bool get isMock => true;

  @override
  Future<void> toggle({required bool enable}) async {
    toggleCalls.add(enable);
    _enabled = enable;
  }

  @override
  Future<bool> get enabled async => _enabled;
}

/// 使用 WakelockMixin 的测试 Widget
class _TestWidget extends StatefulWidget {
  const _TestWidget();

  @override
  State<_TestWidget> createState() => _TestWidgetState();
}

class _TestWidgetState extends State<_TestWidget> with WakelockMixin {
  @override
  Widget build(BuildContext context) {
    return const SizedBox();
  }
}

void main() {
  group('WakelockMixin', () {
    late _MockWakelockPlatform mockPlatform;
    late WakelockPlusPlatformInterface originalPlatform;

    setUp(() {
      originalPlatform = wakelockPlusPlatformInstance;
      mockPlatform = _MockWakelockPlatform();
      wakelockPlusPlatformInstance = mockPlatform;
    });

    tearDown(() {
      wakelockPlusPlatformInstance = originalPlatform;
    });

    testWidgets('initState 时调用 WakelockPlus.enable', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _TestWidget()));
      await tester.pump();

      // 应有 toggle(enable: true) 调用
      expect(
        mockPlatform.toggleCalls,
        contains(true),
        reason: 'WakelockPlus.enable 应在 initState 时被调用',
      );
    });

    testWidgets('dispose 时调用 WakelockPlus.disable', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _TestWidget()));
      await tester.pump();

      mockPlatform.toggleCalls.clear();

      // 移除 widget 触发 dispose
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();

      // 应有 toggle(enable: false) 调用
      expect(
        mockPlatform.toggleCalls,
        contains(false),
        reason: 'WakelockPlus.disable 应在 dispose 时被调用',
      );
    });
  });
}
