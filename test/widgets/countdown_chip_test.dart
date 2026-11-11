import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/widgets/common/countdown_chip.dart';

void main() {
  Widget buildChip({
    Duration total = const Duration(seconds: 5),
    bool isPaused = false,
    bool isFastForward = false,
    VoidCallback? onPause,
    VoidCallback? onResume,
    VoidCallback? onTap,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: CountdownChip(
            total: total,
            isPaused: isPaused,
            isFastForward: isFastForward,
            onPause: onPause ?? () {},
            onResume: onResume ?? () {},
            onTap: onTap,
          ),
        ),
      ),
    );
  }

  group('CountdownChip', () {
    testWidgets('初始状态显示总秒数和暂停徽章', (tester) async {
      await tester.pumpWidget(buildChip(total: const Duration(seconds: 5)));

      // 刚开始时显示 5 秒
      expect(find.text('5'), findsOneWidget);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    });

    testWidgets('暂停时显示播放徽章', (tester) async {
      await tester.pumpWidget(buildChip(isPaused: true));

      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
    });

    testWidgets('倒计时中点击调用 onPause', (tester) async {
      var pauseCalled = false;
      var resumeCalled = false;

      await tester.pumpWidget(
        buildChip(
          isPaused: false,
          onPause: () => pauseCalled = true,
          onResume: () => resumeCalled = true,
        ),
      );

      await tester.tap(find.text('5'));
      await tester.pumpAndSettle();

      expect(pauseCalled, isTrue);
      expect(resumeCalled, isFalse);
    });

    testWidgets('暂停中点击调用 onResume', (tester) async {
      var pauseCalled = false;
      var resumeCalled = false;

      await tester.pumpWidget(
        buildChip(
          isPaused: true,
          onPause: () => pauseCalled = true,
          onResume: () => resumeCalled = true,
        ),
      );

      await tester.tap(find.text('5'));
      await tester.pumpAndSettle();

      expect(pauseCalled, isFalse);
      expect(resumeCalled, isTrue);
    });

    testWidgets('提供自定义点击动作时不触发暂停或恢复', (tester) async {
      var actionCalled = false;
      var pauseCalled = false;
      var resumeCalled = false;

      await tester.pumpWidget(
        buildChip(
          onTap: () => actionCalled = true,
          onPause: () => pauseCalled = true,
          onResume: () => resumeCalled = true,
        ),
      );

      await tester.tap(find.text('5'));
      await tester.pump();

      expect(actionCalled, isTrue);
      expect(pauseCalled, isFalse);
      expect(resumeCalled, isFalse);
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
      expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    });

    testWidgets('动画推进后进度环和秒数更新', (tester) async {
      await tester.pumpWidget(buildChip(total: const Duration(seconds: 5)));

      // 初始进度为 0
      final progressFinder = find.byType(CircularProgressIndicator);
      expect(progressFinder, findsOneWidget);
      var progress = tester.widget<CircularProgressIndicator>(progressFinder);
      expect(progress.value, closeTo(0.0, 0.01));

      // 推进 2 秒，进度应为 0.4
      await tester.pump(const Duration(seconds: 2));
      progress = tester.widget<CircularProgressIndicator>(progressFinder);
      expect(progress.value!, closeTo(0.4, 0.05));

      // 秒数应为 3
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('暂停时动画不推进', (tester) async {
      await tester.pumpWidget(
        buildChip(total: const Duration(seconds: 5), isPaused: true),
      );

      final progressFinder = find.byType(CircularProgressIndicator);
      var progress = tester.widget<CircularProgressIndicator>(progressFinder);
      final initialValue = progress.value!;

      // 推进 2 秒
      await tester.pump(const Duration(seconds: 2));
      progress = tester.widget<CircularProgressIndicator>(progressFinder);

      // 进度不应变化
      expect(progress.value, closeTo(initialValue, 0.01));
    });
  });
}
