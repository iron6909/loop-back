import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/widgets/player_hotkey_scope.dart';

void main() {
  group('LearningHotkeyScope', () {
    /// 模拟按键事件的辅助方法
    Future<void> sendKeyDown(
      WidgetTester tester,
      LogicalKeyboardKey key,
    ) async {
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyUpEvent(key);
      await tester.pump();
    }

    testWidgets('Space 键触发 onPlayPause 回调', (tester) async {
      var called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: LearningHotkeyScope(
            onPlayPause: () => called = true,
            child: const Text('child'),
          ),
        ),
      );

      await sendKeyDown(tester, LogicalKeyboardKey.space);
      expect(called, isTrue);
    });

    testWidgets('Left Arrow 触发 onPrevious 回调', (tester) async {
      var called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: LearningHotkeyScope(
            onPrevious: () => called = true,
            child: const Text('child'),
          ),
        ),
      );

      await sendKeyDown(tester, LogicalKeyboardKey.arrowLeft);
      expect(called, isTrue);
    });

    testWidgets('Right Arrow 触发 onNext 回调', (tester) async {
      var called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: LearningHotkeyScope(
            onNext: () => called = true,
            child: const Text('child'),
          ),
        ),
      );

      await sendKeyDown(tester, LogicalKeyboardKey.arrowRight);
      expect(called, isTrue);
    });

    testWidgets('onPrevious 为 null 时按 Left Arrow 不崩溃', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: LearningHotkeyScope(child: const Text('child'))),
      );

      // 不应该抛出异常
      await sendKeyDown(tester, LogicalKeyboardKey.arrowLeft);
    });

    testWidgets('onPlayPause 为 null 时按 Space 不崩溃', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: LearningHotkeyScope(child: const Text('child'))),
      );

      await sendKeyDown(tester, LogicalKeyboardKey.space);
    });

    testWidgets('onNext 为 null 时按 Right Arrow 不崩溃', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: LearningHotkeyScope(child: const Text('child'))),
      );

      await sendKeyDown(tester, LogicalKeyboardKey.arrowRight);
    });

    testWidgets('非注册按键不触发任何回调', (tester) async {
      var playPauseCalled = false;
      var previousCalled = false;
      var nextCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: LearningHotkeyScope(
            onPlayPause: () => playPauseCalled = true,
            onPrevious: () => previousCalled = true,
            onNext: () => nextCalled = true,
            child: const Text('child'),
          ),
        ),
      );

      // 按下非注册按键
      await sendKeyDown(tester, LogicalKeyboardKey.keyA);
      await sendKeyDown(tester, LogicalKeyboardKey.enter);
      await sendKeyDown(tester, LogicalKeyboardKey.escape);

      expect(playPauseCalled, isFalse);
      expect(previousCalled, isFalse);
      expect(nextCalled, isFalse);
    });

    testWidgets('所有回调同时注册时各自独立触发', (tester) async {
      var playPauseCount = 0;
      var previousCount = 0;
      var nextCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: LearningHotkeyScope(
            onPlayPause: () => playPauseCount++,
            onPrevious: () => previousCount++,
            onNext: () => nextCount++,
            child: const Text('child'),
          ),
        ),
      );

      await sendKeyDown(tester, LogicalKeyboardKey.space);
      await sendKeyDown(tester, LogicalKeyboardKey.arrowLeft);
      await sendKeyDown(tester, LogicalKeyboardKey.arrowRight);
      await sendKeyDown(tester, LogicalKeyboardKey.space);

      expect(playPauseCount, 2);
      expect(previousCount, 1);
      expect(nextCount, 1);
    });

    testWidgets('child 组件正确渲染', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: LearningHotkeyScope(child: const Text('test child'))),
      );

      expect(find.text('test child'), findsOneWidget);
    });
  });
}
