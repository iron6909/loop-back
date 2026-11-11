/// AI 服务页的完整配置流程：先选供应商，再填 Key；自定义配置不丢失。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:loop_back/features/provider_settings/screens/ai_service_screen.dart';
import 'package:loop_back/l10n/app_localizations.dart';
import 'package:loop_back/providers/provider_configuration_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../helpers/provider_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderFixture fixture;
  tearDown(() => fixture.dispose());

  Future<void> pump(WidgetTester tester) async {
    fixture = ProviderFixture();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AiServiceScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> edit(WidgetTester tester, String label, String value) async {
    await tester.ensureVisible(find.text(label).first);
    await tester.tap(find.text(label).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), value);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
  }

  testWidgets('先选预设但未填 Key，仍可继续编辑并完成连接验证', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Configure provider'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DeepSeek'));
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.pump();
    expect(find.text('https://api.deepseek.com'), findsOneWidget);
    expect(fixture.adapter.requests, isEmpty);
    fixture.adapter.json({
      'balance_infos': [
        {'currency': 'CNY', 'total_balance': '3'},
      ],
    });
    await edit(tester, 'API key', 'synthetic-ui-key');
    await tester.pump();
    await tester.pump();
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('synthetic-ui-key'), findsNothing);
    final reply = Completer<ResponseBody>();
    fixture.adapter.replies.add((_) => reply.future);
    await tester.ensureVisible(find.text('Test'));
    await tester.tap(find.text('Test'));
    await tester.pump();
    expect(find.text('Not tested'), findsNothing);
    final testButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(testButton.onPressed, isNull);
    // 状态行与按钮标签同时显示测试中。
    expect(find.text('Testing…'), findsNWidgets(2));
    reply.complete(
      ResponseBody.fromString(
        jsonEncode({
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {'content': 'OK'},
            },
          ],
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Connection OK'), findsOneWidget);
    expect(find.text('Not tested'), findsNothing);
    fixture.adapter.json({
      'balance_infos': [
        {'currency': 'CNY', 'total_balance': '3'},
      ],
    });
    await edit(tester, 'Model', 'another-model');
    expect(find.text('Connection OK'), findsNothing);
    expect(find.text('Not tested'), findsOneWidget);
    await edit(tester, 'API key', '');
    expect(
      await fixture.container.read(providerConfigurationProvider.future),
      isNull,
    );
    expect(find.text('https://api.deepseek.com'), findsOneWidget);
  });

  testWidgets('连接验证拒绝空正文和截断结果，鉴权失败以内联提示', (tester) async {
    await pump(tester);
    await fixture.configure();
    await tester.pumpAndSettle();
    for (final finish in ['stop', 'length']) {
      fixture.adapter.json({
        'choices': [
          {
            'finish_reason': finish,
            'message': {'content': finish == 'stop' ? '' : 'partial'},
          },
        ],
      });
      await tester.ensureVisible(find.text('Test'));
      await tester.tap(find.text('Test'));
      await tester.pumpAndSettle();
      expect(find.text('Connection OK'), findsNothing);
      expect(
        find.text('AI returned an invalid result. Try again'),
        findsOneWidget,
      );
    }
    fixture.adapter.json({'error': 'unauthorized'}, status: 401);
    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('API key is invalid or unauthorized'), findsOneWidget);
    expect(find.text('Not tested'), findsNothing);
  });

  testWidgets('自定义地址和模型分步保存；无 Key 时不发请求', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Configure provider'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'invalid');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a complete HTTP or HTTPS address'), findsOneWidget);
    await tester.enterText(
      find.byType(TextField),
      'https://provider.example/v1',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'chosen-model');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.pump();
    expect(find.text('chosen-model'), findsOneWidget);
    expect(fixture.adapter.requests, isEmpty);
  });

  testWidgets('从未配置：居中空态说明用途与支持的服务，不展示配置行', (tester) async {
    await pump(tester);

    expect(find.text('AI service is not configured'), findsOneWidget);
    expect(
      find.text(
        'Works with DeepSeek, OpenRouter and any OpenAI-compatible service',
      ),
      findsOneWidget,
    );
    expect(find.text('Configure provider'), findsOneWidget);
    // 空态不应同时渲染可编辑的配置行与连接验证。
    expect(find.text('Base URL'), findsNothing);
    expect(find.text('Connection'), findsNothing);
    expect(find.text('Connection test'), findsNothing);
  });

  testWidgets('已配置：供应商卡展示身份信息，连接配置单独成组', (tester) async {
    await pump(tester);
    await fixture.configure();
    await tester.pumpAndSettle();

    final card = find.byKey(const Key('ai-service-provider-card'));
    expect(
      find.descendant(of: card, matching: find.text('Custom')),
      findsOneWidget,
    );
    expect(find.text('fixture-model · provider.example'), findsOneWidget);
    expect(find.byTooltip('Change provider'), findsOneWidget);
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Connection test'), findsOneWidget);
  });
}
