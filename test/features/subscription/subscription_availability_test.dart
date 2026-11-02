/// 订阅可用性门控测试。
///
/// 覆盖 [openPaywall] 的平台门控：平台未启用订阅时不导航、弹提示；
/// 启用时正常跳转 Paywall 路由。
library;

import 'package:echo_loop/features/subscription/providers/subscription_availability.dart';
import 'package:echo_loop/config/client_distribution.dart';
import 'package:echo_loop/features/subscription/widgets/feature_gate.dart';
import 'package:echo_loop/l10n/app_localizations.dart';
import 'package:echo_loop/router/app_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 带路由的测试壳：首页一个按钮调用 [openPaywall]，`/paywall` 为占位页。
Widget _harness({required bool available}) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => openPaywall(context, ref),
              child: const Text('go'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.paywall,
        builder: (context, state) =>
            const Scaffold(body: Text('Paywall Route')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [subscriptionAvailabilityProvider.overrideWithValue(available)],
    child: MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('zh')],
    ),
  );
}

void main() {
  group('本地渠道支付裁决', () {
    test('app_store / play 只认原生商店配置', () {
      for (final channel in [
        ClientPaymentChannel.appleStore,
        ClientPaymentChannel.googlePlay,
      ]) {
        expect(
          subscriptionAvailableFor(
            channel: channel,
            nativeStoreConfigured: true,
            webConfigured: false,
          ),
          isTrue,
        );
        expect(
          subscriptionAvailableFor(
            channel: channel,
            nativeStoreConfigured: false,
            webConfigured: true,
          ),
          isFalse,
        );
      }
    });

    test('direct 只认 Web checkout 配置', () {
      expect(
        subscriptionAvailableFor(
          channel: ClientPaymentChannel.web,
          nativeStoreConfigured: true,
          webConfigured: false,
        ),
        isFalse,
      );
      expect(
        subscriptionAvailableFor(
          channel: ClientPaymentChannel.web,
          nativeStoreConfigured: false,
          webConfigured: true,
        ),
        isTrue,
      );
      expect(
        webCheckoutModeFor(
          channel: ClientPaymentChannel.web,
          webConfigured: true,
        ),
        isTrue,
      );
    });

    test('商店包 Web 支付入口需要商店渠道、Paddle 配置和远程开关同时满足', () {
      for (final channel in [
        ClientPaymentChannel.appleStore,
        ClientPaymentChannel.googlePlay,
      ]) {
        expect(
          showStoreWebCheckoutFallbackFor(
            channel: channel,
            webConfigured: true,
            remoteEnabled: true,
          ),
          isTrue,
        );
        expect(
          showStoreWebCheckoutFallbackFor(
            channel: channel,
            webConfigured: false,
            remoteEnabled: true,
          ),
          isFalse,
        );
        expect(
          showStoreWebCheckoutFallbackFor(
            channel: channel,
            webConfigured: true,
            remoteEnabled: false,
          ),
          isFalse,
        );
      }
      expect(
        showStoreWebCheckoutFallbackFor(
          channel: ClientPaymentChannel.web,
          webConfigured: true,
          remoteEnabled: true,
        ),
        isFalse,
      );
    });

    test('未知 identity 保守隐藏', () {
      expect(
        subscriptionAvailableFor(
          channel: ClientPaymentChannel.unavailable,
          nativeStoreConfigured: true,
          webConfigured: true,
        ),
        isFalse,
      );
    });
  });

  testWidgets('订阅已停用：openPaywall 不导航，只弹平台不支持提示', (tester) async {
    await tester.pumpWidget(_harness(available: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('Paywall Route'), findsNothing);
    expect(
      find.text('Subscriptions are not yet available on this platform'),
      findsOneWidget,
    );
  });
}
