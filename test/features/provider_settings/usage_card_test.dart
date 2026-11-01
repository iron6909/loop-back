/// 用量卡九态：只读展示，任何状态都不显示 0 或虚构数字（ui-spec S2）。
library;
import 'package:echo_loop/features/provider_settings/widgets/usage_card.dart';
import 'package:echo_loop/l10n/app_localizations.dart';
import 'package:echo_loop/services/provider/usage_models.dart';
import 'package:echo_loop/services/provider/usage_query_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    UsageView view, {
    bool isRefreshing = false,
    Future<void> Function()? onRefresh,
    String providerName = 'DeepSeek',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: UsageCard(
            view: view,
            providerName: providerName,
            isRefreshing: isRefreshing,
            onRefresh: onRefresh ?? () async {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  UsageSnapshot amounts(List<UsageAmount> values, {UsageScope scope = UsageScope.account}) =>
      UsageSnapshot(scope: scope, amounts: values);

  testWidgets('首次加载：骨架占位，不显示任何数字', (tester) async {
    await pump(tester, const UsageView());

    // 标题仍显示供应商名，但正文不能出现金额或百分比。
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.textContaining('0.00'), findsNothing);
    expect(find.textContaining('%'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('金额余额：主值带币种，并展开赠送与充值', (tester) async {
    await pump(
      tester,
      UsageView(
        snapshot: amounts([
          const UsageAmount(currency: 'CNY', total: 110, granted: 10, toppedUp: 100),
        ]),
        fetchedAt: DateTime(2026, 11, 1, 11, 20),
      ),
    );

    expect(find.text('¥110.00 CNY'), findsOneWidget);
    expect(find.text('Granted ¥10.00 · Topped up ¥100.00'), findsOneWidget);
    expect(find.text('Updated 11:20'), findsOneWidget);
    expect(find.textContaining('Account balance'), findsOneWidget);
  });

  testWidgets('多币种各占一行，不合并成一个数字', (tester) async {
    await pump(
      tester,
      UsageView(
        snapshot: amounts([
          const UsageAmount(currency: 'CNY', total: 110),
          const UsageAmount(currency: 'USD', total: 5),
        ]),
        fetchedAt: DateTime(2026, 11, 1, 9, 5),
      ),
    );

    expect(find.text('¥110.00 CNY'), findsOneWidget);
    expect(find.text(r'$5.00 USD'), findsOneWidget);
  });

  testWidgets('Key 未设预算：显示未设预算而不是 0', (tester) async {
    await pump(
      tester,
      UsageView(
        snapshot: const UsageSnapshot(scope: UsageScope.keyBudget, budgetNotSet: true),
        fetchedAt: DateTime(2026, 11, 1, 8),
      ),
    );

    expect(find.text('No budget set for this key'), findsOneWidget);
    expect(find.textContaining('0.00'), findsNothing);
    expect(find.textContaining('Key budget'), findsOneWidget);
  });

  testWidgets('套餐窗口：剩余最少置顶，percent=0 不显示重置时间', (tester) async {
    await pump(
      tester,
      UsageView(
        snapshot: const UsageSnapshot(
          scope: UsageScope.planWindow,
          windows: [
            UsageWindow(
              kind: UsageWindowKind.rolling,
              usedPercent: 12,
              rateLimited: false,
              resetsAt: null,
            ),
            UsageWindow(
              kind: UsageWindowKind.weekly,
              usedPercent: 80,
              rateLimited: false,
              resetsAt: null,
            ),
            UsageWindow(kind: UsageWindowKind.monthly, usedPercent: 5, rateLimited: false),
          ],
        ),
        fetchedAt: DateTime(2026, 11, 1, 7),
      ),
    );

    expect(find.text('Weekly'), findsOneWidget);
    expect(find.text('80%'), findsOneWidget);
    // percent=0 的占位重置时间被丢弃：三行都不带 Resets。
    expect(find.textContaining('Resets'), findsNothing);
  });

  testWidgets('已限额：图标 + 文字双通道', (tester) async {
    await pump(
      tester,
      UsageView(
        snapshot: const UsageSnapshot(
          scope: UsageScope.planWindow,
          windows: [
            UsageWindow(
              kind: UsageWindowKind.rolling,
              usedPercent: 99,
              rateLimited: true,
            ),
          ],
        ),
        fetchedAt: DateTime(2026, 11, 1, 6),
      ),
    );

    expect(find.text('Rate limited'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('不支持查询：只给说明，不展示任何数字', (tester) async {
    await pump(
      tester,
      const UsageView(unsupported: true),
      providerName: 'Custom',
    );

    expect(find.text('This address does not support usage queries'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('00'), findsNothing);
  });

  testWidgets('刷新失败但有旧数据：保留旧值并给更新时间与重试', (tester) async {
    var retried = 0;
    await pump(
      tester,
      UsageView(
        snapshot: amounts([const UsageAmount(currency: 'CNY', total: 88)]),
        fetchedAt: DateTime(2026, 11, 1, 11, 20),
        failed: true,
      ),
      onRefresh: () async => retried++,
    );

    expect(find.text('¥88.00 CNY'), findsOneWidget);
    expect(find.text('Update failed · last 11:20'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retried, 1);
  });

  testWidgets('从未成功：显示暂无法获取与重试，不给数字', (tester) async {
    await pump(tester, const UsageView(failed: true));

    expect(find.text('Currently unavailable'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('00'), findsNothing);
  });

  testWidgets('刷新中：按钮禁用并转圈', (tester) async {
    await pump(
      tester,
      UsageView(
        snapshot: amounts([const UsageAmount(currency: 'USD', total: 1)]),
        fetchedAt: DateTime(2026, 11, 1, 10),
      ),
      isRefreshing: true,
    );

    final button = tester.widget<IconButton>(find.byType(IconButton));
    expect(button.onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
