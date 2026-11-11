// 睡眠定时器按钮与浮层 widget 测试。
//
// 覆盖：未激活渲染 6 档预设；点选启动并收起浮层、图标转激活态；激活态浮层显示
// 剩余时间 + 关闭项 + 当前档打勾；点关闭恢复未激活。
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/l10n/app_localizations.dart';
import 'package:loop_back/theme/app_theme.dart';
import 'package:loop_back/widgets/sleep_timer.dart';

Widget _buildTestApp() {
  return ProviderScope(
    child: MaterialApp(
      supportedLocales: const [Locale('en'), Locale('zh')],
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Player'),
          actions: const [SleepTimerButton()],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('未激活：点按钮弹出 6 档预设', (tester) async {
    await tester.pumpWidget(_buildTestApp());

    // 初始未激活：timer_outlined 图标。
    expect(find.byIcon(Icons.timer_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.timer_outlined));
    await tester.pumpAndSettle();

    // 浮层顶部显示标题。
    expect(find.text('Sleep timer'), findsOneWidget);

    for (final m in [5, 10, 15, 30, 45, 60]) {
      expect(find.text('$m min'), findsOneWidget);
    }
    // 未激活时无「关闭定时」「剩余时间」。
    expect(find.text('Turn off timer'), findsNothing);
  });

  testWidgets('点选预设启动定时并收起浮层、右上角改为倒计时胶囊', (tester) async {
    await tester.pumpWidget(_buildTestApp());

    await tester.tap(find.byIcon(Icons.timer_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 min'));
    await tester.pumpAndSettle();

    // 浮层收起（预设行消失），右上角改为倒计时而不是实心图标。
    expect(find.text('5 min'), findsNothing);
    expect(find.byIcon(Icons.timer), findsNothing);
    expect(find.textContaining(RegExp(r'^\d\d:\d\d$')), findsOneWidget);
  });

  testWidgets('激活态浮层只显示关闭项与当前档打勾，不再显示大号倒计时', (tester) async {
    await tester.pumpWidget(_buildTestApp());

    await tester.tap(find.byIcon(Icons.timer_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 min'));
    await tester.pumpAndSettle();

    // 再次打开浮层。
    await tester.tap(find.textContaining(RegExp(r'^\d\d:\d\d$')));
    await tester.pumpAndSettle();

    expect(find.text('Time remaining'), findsNothing);
    expect(find.text('Turn off timer'), findsOneWidget);
    // 当前档打勾。
    expect(find.byIcon(Icons.check), findsOneWidget);

    // 点关闭：恢复未激活。
    await tester.tap(find.text('Turn off timer'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.timer_outlined), findsOneWidget);
    expect(find.byIcon(Icons.timer), findsNothing);
  });

  testWidgets('关闭定时时图标从第一帧就在最终位置，不再二次右跳', (tester) async {
    await tester.pumpWidget(_buildTestApp());

    await tester.tap(find.byIcon(Icons.timer_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 min'));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining(RegExp(r'^\d\d:\d\d$')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn off timer'));
    await tester.pump(const Duration(milliseconds: 40));

    final earlyDx = tester.getTopRight(find.byIcon(Icons.timer_outlined)).dx;

    await tester.pumpAndSettle();

    final settledDx = tester.getTopRight(find.byIcon(Icons.timer_outlined)).dx;
    expect(earlyDx, closeTo(settledDx, 0.01));
  });

  testWidgets('激活一段时间后当前预设仍保持打勾', (tester) async {
    await tester.pumpWidget(_buildTestApp());

    await tester.tap(find.byIcon(Icons.timer_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 min'));
    await tester.pump(const Duration(minutes: 3, seconds: 12));

    await tester.tap(find.textContaining(RegExp(r'^\d\d:\d\d$')));
    await tester.pumpAndSettle();

    expect(find.text('30 min'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });
}
