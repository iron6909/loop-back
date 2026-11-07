/// 在线语音服务配置区：状态显示与编辑只落本机配置，不发请求。
library;

import 'package:echo_loop/l10n/app_localizations.dart';
import 'package:echo_loop/providers/speech_configuration_provider.dart';
import 'package:echo_loop/services/speech/speech_config.dart';
import 'package:echo_loop/services/speech/speech_config_store.dart';
import 'package:echo_loop/theme/app_theme.dart';
import 'package:echo_loop/widgets/asr/speech_provider_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只保存在内存里的配置替身：界面测试不触碰安全存储与普通偏好。
class _InMemorySpeechConfigStore extends SpeechConfigStore {
  _InMemorySpeechConfigStore({this.config, this.apiKey, this.failSave = false});

  SpeechConfig? config;
  String? apiKey;
  bool failSave;

  @override
  Future<SpeechConfig?> read() async => config;

  @override
  Future<String?> readApiKey() async => apiKey;

  @override
  Future<String?> readCredentialVersion() async => 'test-credential-version';

  @override
  Future<void> save(SpeechConfig value, {String? apiKey}) async {
    if (failSave) throw StateError('secure storage unavailable');
    config = value;
    if (apiKey != null) {
      final next = apiKey.trim();
      this.apiKey = next.isEmpty ? null : next;
    }
  }
}

const _openRouterConfig = SpeechConfig(
  kind: SpeechProviderKind.openrouter,
  baseUrl: 'https://openrouter.ai/api/v1',
);

void main() {
  Widget app(SpeechConfigStore speechStore) => ProviderScope(
    overrides: [speechConfigStoreProvider.overrideWithValue(speechStore)],
    child: MaterialApp(
      locale: const Locale('en'),
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light(),
      home: const Scaffold(
        body: SingleChildScrollView(child: SpeechProviderSection()),
      ),
    ),
  );

  testWidgets('未配置时显示未配置状态', (tester) async {
    await tester.pumpWidget(app(_InMemorySpeechConfigStore()));
    await tester.pumpAndSettle();

    expect(find.text('Not configured'), findsOneWidget);
    expect(find.text('Not set'), findsOneWidget);
  });

  testWidgets('已保存配置但缺 Key 显示缺少 Key', (tester) async {
    await tester.pumpWidget(
      app(_InMemorySpeechConfigStore(config: _openRouterConfig)),
    );
    await tester.pumpAndSettle();

    expect(find.text('API key missing'), findsOneWidget);
    expect(find.text('https://openrouter.ai/api/v1'), findsOneWidget);
  });

  testWidgets('配置与 Key 齐备时显示已保存未验证，且不回显 Key', (tester) async {
    await tester.pumpWidget(
      app(
        _InMemorySpeechConfigStore(
          config: _openRouterConfig,
          apiKey: 'sk-speech-sentinel-4b7d',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Saved, not verified'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.textContaining('sk-sebavz'), findsNothing);
  });

  testWidgets('选择自定义服务并填写根地址后保存配置', (tester) async {
    final store = _InMemorySpeechConfigStore();
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Provider'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.byType(TextField),
      'https://speech.example.com/proxy/stt',
    );
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(store.config?.kind, SpeechProviderKind.custom);
    expect(store.config?.baseUrl, 'https://speech.example.com/proxy/stt');
    expect(store.apiKey, isNull);
    expect(find.text('API key missing'), findsOneWidget);
  });

  testWidgets('保存失败时提示原因且不显示为已保存', (tester) async {
    await tester.pumpWidget(app(_InMemorySpeechConfigStore(failSave: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Provider'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenRouter'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('Could not save the online speech settings'),
      findsOneWidget,
    );
    expect(find.text('Not configured'), findsOneWidget);
  });
}
