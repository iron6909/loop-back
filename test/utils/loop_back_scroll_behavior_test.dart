import 'package:loop_back/utils/loop_back_scroll_behavior.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<VelocityTracker> trackerForPlatform(
    WidgetTester tester,
    TargetPlatform platform,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Builder(
          builder: (buildContext) {
            context = buildContext;
            return const SizedBox();
          },
        ),
      ),
    );
    return LoopBackScrollBehavior().velocityTrackerBuilder(context)(
      const PointerPanZoomStartEvent(),
    );
  }

  testWidgets('macOS 使用通用追踪器，接受乱序触控板时间戳', (tester) async {
    final tracker = await trackerForPlatform(tester, TargetPlatform.macOS);

    expect(tracker, isNot(isA<MacOSScrollViewFlingVelocityTracker>()));
    tracker
      ..addPosition(const Duration(microseconds: 2), Offset.zero)
      ..addPosition(const Duration(microseconds: 1), const Offset(1, 1));
  });

  testWidgets('iOS 保留原生滚动惯性追踪器', (tester) async {
    final tracker = await trackerForPlatform(tester, TargetPlatform.iOS);

    expect(tracker, isA<IOSScrollViewFlingVelocityTracker>());
  });
}
