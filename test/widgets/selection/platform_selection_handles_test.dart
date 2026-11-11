/// 平台文本选择手柄几何回归测试。
library;

import 'package:loop_back/widgets/selection/platform_selection_handles.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpHandle(
    WidgetTester tester, {
    required TargetPlatform platform,
    required TextSelectionHandleType type,
  }) async {
    final controls = switch (platform) {
      TargetPlatform.iOS => cupertinoTextSelectionHandleControls,
      TargetPlatform.android => materialTextSelectionHandleControls,
      _ => throw ArgumentError('仅覆盖移动端平台'),
    };
    const anchor = Rect.fromLTWH(24, 20, 48, 24);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: Stack(
            clipBehavior: Clip.none,
            children: [
              SelectionHandle(
                key: const Key('selection_handle'),
                controls: controls,
                anchor: anchor,
                isStart: type == TextSelectionHandleType.left,
                onDragStart: (_) {},
                onDragUpdate: (_) {},
                onDragEnd: () {},
                onDragCancel: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final type in [
      TextSelectionHandleType.left,
      TextSelectionHandleType.right,
    ]) {
      testWidgets('$platform $type 使用选区底部作为手柄锚点', (tester) async {
        await pumpHandle(tester, platform: platform, type: type);
        final controls = platform == TargetPlatform.android
            ? materialTextSelectionHandleControls
            : cupertinoTextSelectionHandleControls;
        const anchor = Rect.fromLTWH(24, 20, 48, 24);
        final size = controls.getHandleSize(anchor.height);
        final handleAnchor = controls.getHandleAnchor(type, anchor.height);
        final endpoint = type == TextSelectionHandleType.left
            ? Offset(anchor.left, anchor.bottom)
            : Offset(anchor.right, anchor.bottom);
        final expectedCenter =
            endpoint - handleAnchor + Offset(size.width / 2, size.height / 2);

        expect(
          tester.getRect(find.byKey(const Key('selection_handle'))).center,
          expectedCenter,
        );
      });
    }
  }
}
