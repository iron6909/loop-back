/// 在线语音服务配置区：状态显示、能力验证与上传告知。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:echo_loop/l10n/app_localizations.dart';
import 'package:echo_loop/models/recognition_selection.dart';
import 'package:echo_loop/providers/recognition_settings_provider.dart';
import 'package:echo_loop/providers/speech_capability_provider.dart';
import 'package:echo_loop/providers/speech_configuration_provider.dart';
import 'package:echo_loop/services/speech/speech_capability.dart';
import 'package:echo_loop/services/speech/speech_capability_probe.dart';
import 'package:echo_loop/services/speech/speech_config.dart';
import 'package:echo_loop/services/speech/speech_config_store.dart';
import 'package:echo_loop/services/speech/speech_model_catalog.dart';
import 'package:echo_loop/services/speech/speech_transcription_client.dart';
import 'package:echo_loop/theme/app_theme.dart';
import 'package:echo_loop/screens/speech_provider_settings_screen.dart';
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

  /// 与真实存储一致：Key 一变就换凭据版本，旧能力验证随之失效。
  String? credentialVersion = 'test-credential-version';
  int _credentialUpdates = 0;

  @override
  Future<SpeechConfig?> read() async => config;

  @override
  Future<String?> readApiKey() async => apiKey;

  @override
  Future<String?> readCredentialVersion() async => credentialVersion;

  @override
  Future<void> save(SpeechConfig value, {String? apiKey}) async {
    if (failSave) throw StateError('secure storage unavailable');
    config = value;
    if (apiKey != null) {
      final next = apiKey.trim();
      final keyChanged = (next.isEmpty ? null : next) != this.apiKey;
      this.apiKey = next.isEmpty ? null : next;
      if (keyChanged) {
        credentialVersion = 'test-credential-version-${++_credentialUpdates}';
      }
    }
  }
}

const _openRouterConfig = SpeechConfig(
  kind: SpeechProviderKind.openrouter,
  baseUrl: 'https://openrouter.ai/api/v1',
);

const _openRouterConfigWithModels = SpeechConfig(
  kind: SpeechProviderKind.openrouter,
  baseUrl: 'https://openrouter.ai/api/v1',
  onlineModels: {
    RecognitionPurpose.subtitle: 'openai/whisper-large-v3',
    RecognitionPurpose.shadowing: 'openai/whisper-large-v3',
  },
);

/// 与待验证配置身份匹配的结论。
SpeechCapability _capability({
  required String modelId,
  required bool segments,
  bool words = false,
  double? cost,
}) => SpeechCapability(
  identity: SpeechCapability.identityFor(
    kind: SpeechProviderKind.openrouter,
    baseUrl: 'https://openrouter.ai/api/v1',
    modelId: modelId,
    credentialVersion: 'test-credential-version',
  ),
  text: true,
  segments: segments,
  wordTimestamps: words,
  validatedAt: DateTime.utc(2026, 11, 7, 12),
  reportedCost: cost,
);

/// 只保存在内存里的能力记录替身，不碰普通偏好。
class _InMemoryCapabilityStore extends SpeechCapabilityStore {
  final Map<String, SpeechCapability> records = {};
  final Set<String> notices = {};

  @override
  Future<Map<String, SpeechCapability>> readAll() async => Map.of(records);

  @override
  Future<SpeechCapability?> read(String identity) async => records[identity];

  @override
  Future<void> save(SpeechCapability capability) async =>
      records[capability.identity] = capability;

  @override
  Future<bool> hasUploadNotice(String baseUrl) async =>
      notices.contains(baseUrl);

  @override
  Future<void> rememberUploadNotice(String baseUrl) async =>
      notices.add(baseUrl);

  @override
  Future<void> clear() async {
    records.clear();
    notices.clear();
  }
}

/// 可控的能力验证替身：不发付费请求。
class _FakeProbe implements SpeechCapabilityProbe {
  int runCount = 0;
  SpeechCapability? capability;
  Object? failure;

  @override
  Future<SpeechCapability> run({
    required SpeechConfig config,
    required String apiKey,
    required String modelId,
    required String? credentialVersion,
    CancelToken? cancelToken,
  }) async {
    runCount++;
    if (failure case final error?) throw error;
    return capability ?? (throw StateError('没有预设结论'));
  }
}

/// 可控的模型目录替身。
class _FakeCatalog implements SpeechModelCatalogClient {
  List<String> models = const [];
  Object? failure;
  int callCount = 0;
  Completer<void>? _pending;

  /// 挂起下一次目录请求，直到测试完成返回的 Future。
  Completer<void> hold() => _pending = Completer<void>();

  @override
  Future<List<String>> fetchTranscriptionModels({
    required SpeechConfig config,
    required String apiKey,
    CancelToken? cancelToken,
  }) async {
    callCount++;
    if (_pending case final pending?) await pending.future;
    if (failure case final error?) throw error;
    return models;
  }
}

void main() {
  Widget app(
    SpeechConfigStore speechStore, {
    SpeechCapabilityStore? capabilityStore,
    SpeechCapabilityProbe? probe,
    SpeechModelCatalogClient? catalog,
    RecognitionInFlightRegistry? inFlightRegistry,
  }) => ProviderScope(
    overrides: [
      speechConfigStoreProvider.overrideWithValue(speechStore),
      if (capabilityStore != null)
        speechCapabilityStoreProvider.overrideWithValue(capabilityStore),
      if (probe != null) speechCapabilityProbeProvider.overrideWithValue(probe),
      if (catalog != null)
        speechModelCatalogClientProvider.overrideWithValue(catalog),
      if (inFlightRegistry != null)
        recognitionInFlightTasksProvider.overrideWithValue(inFlightRegistry),
    ],
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
      home: const SpeechProviderSettingsScreen(),
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

  testWidgets('手填模型 ID 始终可编辑', (tester) async {
    final store = _InMemorySpeechConfigStore(
      config: _openRouterConfig,
      apiKey: 'sk-speech-sentinel-4b7d',
    );
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Subtitles online model'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'openai/whisper-large-v3');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      store.config?.onlineModelFor(RecognitionPurpose.subtitle),
      'openai/whisper-large-v3',
    );
  });

  testWidgets('获取转写模型只在点击后拉取一次，三个用途共用同一份列表', (tester) async {
    final store = _InMemorySpeechConfigStore(
      config: _openRouterConfig,
      apiKey: 'sk-speech-sentinel-4b7d',
    );
    final catalog = _FakeCatalog()
      ..models = const ['openai/whisper-large-v3', 'openai/whisper-small'];
    await tester.pumpWidget(app(store, catalog: catalog));
    await tester.pumpAndSettle();

    // 打开页面不自动获取。
    expect(catalog.callCount, 0);

    await tester.tap(find.text('Get transcription models'));
    await tester.pumpAndSettle();

    expect(catalog.callCount, 1);
    expect(find.text('2 transcription models retrieved'), findsOneWidget);

    await tester.tap(find.text('Subtitles online model'));
    await tester.pumpAndSettle();

    expect(find.text('openai/whisper-large-v3'), findsOneWidget);
    expect(find.text('openai/whisper-small'), findsOneWidget);

    await tester.tap(find.text('openai/whisper-large-v3'));
    await tester.pumpAndSettle();

    expect(
      store.config?.onlineModelFor(RecognitionPurpose.subtitle),
      'openai/whisper-large-v3',
    );
    expect(
      store.config?.onlineModelFor(RecognitionPurpose.shadowing),
      '',
      reason: '选择只写当前用途',
    );
    expect(catalog.callCount, 1, reason: '重新打开选择器不再拉取目录');

    // 另一个用途复用同一份列表。
    await tester.tap(find.text('Retelling online model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('openai/whisper-small'));
    await tester.pumpAndSettle();

    expect(
      store.config?.onlineModelFor(RecognitionPurpose.retell),
      'openai/whisper-small',
    );
    expect(catalog.callCount, 1);
  });

  testWidgets('获取中显示加载状态并禁用重复点击', (tester) async {
    final catalog = _FakeCatalog()..models = const ['openai/whisper-large-v3'];
    final pending = catalog.hold();
    await tester.pumpWidget(
      app(
        _InMemorySpeechConfigStore(
          config: _openRouterConfig,
          apiKey: 'sk-speech-sentinel-4b7d',
        ),
        catalog: catalog,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get transcription models'));
    await tester.pump();

    expect(find.text('Getting transcription models…'), findsOneWidget);
    await tester.tap(find.text('Get transcription models'));
    await tester.pump();
    expect(catalog.callCount, 1);

    pending.complete();
    await tester.pumpAndSettle();

    expect(find.text('1 transcription models retrieved'), findsOneWidget);
    expect(find.text('Getting transcription models…'), findsNothing);
  });

  testWidgets('未保存配置时获取按钮禁用并说明先补服务地址', (tester) async {
    final catalog = _FakeCatalog();
    await tester.pumpWidget(
      app(_InMemorySpeechConfigStore(), catalog: catalog),
    );
    await tester.pumpAndSettle();

    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Get transcription models'),
    );
    expect(button.onPressed, isNull);
    expect(find.text('Save a service address to get models'), findsOneWidget);

    await tester.tap(find.text('Get transcription models'));
    await tester.pumpAndSettle();
    expect(catalog.callCount, 0);
  });

  testWidgets('自定义服务隐藏获取按钮，也不显示获取前的状态原因', (tester) async {
    await tester.pumpWidget(
      app(
        _InMemorySpeechConfigStore(
          config: const SpeechConfig(
            kind: SpeechProviderKind.custom,
            baseUrl: 'https://speech.example.com/stt',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Get transcription models'), findsNothing);
    expect(find.text('Save an API key to get models'), findsNothing);
    expect(find.text('Save a service address to get models'), findsNothing);
  });

  testWidgets('获取成功后可以重新获取并更新列表', (tester) async {
    final catalog = _FakeCatalog()..models = const ['openai/whisper-large-v3'];
    await tester.pumpWidget(
      app(
        _InMemorySpeechConfigStore(
          config: _openRouterConfig,
          apiKey: 'sk-speech-sentinel-4b7d',
        ),
        catalog: catalog,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get transcription models'));
    await tester.pumpAndSettle();
    expect(find.text('1 transcription models retrieved'), findsOneWidget);

    catalog.models = const ['openai/whisper-large-v3', 'openai/whisper-small'];
    await tester.tap(find.text('Get transcription models'));
    await tester.pumpAndSettle();

    expect(catalog.callCount, 2);
    expect(find.text('2 transcription models retrieved'), findsOneWidget);

    await tester.tap(find.text('Subtitles online model'));
    await tester.pumpAndSettle();

    expect(find.text('openai/whisper-small'), findsOneWidget);
  });

  testWidgets('缺 API Key 时获取按钮禁用并说明原因', (tester) async {
    final catalog = _FakeCatalog();
    await tester.pumpWidget(
      app(
        _InMemorySpeechConfigStore(config: _openRouterConfig),
        catalog: catalog,
      ),
    );
    await tester.pumpAndSettle();

    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Get transcription models'),
    );
    expect(button.onPressed, isNull);
    expect(find.text('Save an API key to get models'), findsOneWidget);

    await tester.tap(find.text('Get transcription models'));
    await tester.pumpAndSettle();
    expect(catalog.callCount, 0);
  });

  testWidgets('自定义服务隐藏获取按钮，但手填仍可用', (tester) async {
    final store = _InMemorySpeechConfigStore(
      config: const SpeechConfig(
        kind: SpeechProviderKind.custom,
        baseUrl: 'https://speech.example.com/stt',
      ),
      apiKey: 'sk-speech-sentinel-4b7d',
    );
    final catalog = _FakeCatalog();
    await tester.pumpWidget(app(store, catalog: catalog));
    await tester.pumpAndSettle();

    expect(find.text('Get transcription models'), findsNothing);

    await tester.tap(find.text('Shadowing online model'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'whisper-1');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      store.config?.onlineModelFor(RecognitionPurpose.shadowing),
      'whisper-1',
    );
    expect(catalog.callCount, 0);
  });

  testWidgets('获取失败时提示，手填不受影响', (tester) async {
    final catalog = _FakeCatalog()
      ..failure = const SpeechTranscriptionException(
        SpeechTranscriptionErrorKind.network,
      );
    final store = _InMemorySpeechConfigStore(
      config: _openRouterConfig,
      apiKey: 'sk-speech-sentinel-4b7d',
    );
    await tester.pumpWidget(app(store, catalog: catalog));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get transcription models'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Could not load the model list; you can still enter a model ID',
      ),
      findsOneWidget,
    );

    // 列表失败不影响手填。
    await tester.tap(find.text('Subtitles online model'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'openai/whisper-large-v3');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      store.config?.onlineModelFor(RecognitionPurpose.subtitle),
      'openai/whisper-large-v3',
    );
  });

  testWidgets('列表为空时提示，手填不受影响', (tester) async {
    final catalog = _FakeCatalog()..models = const [];
    final store = _InMemorySpeechConfigStore(
      config: _openRouterConfig,
      apiKey: 'sk-speech-sentinel-4b7d',
    );
    await tester.pumpWidget(app(store, catalog: catalog));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get transcription models'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'The service returned no transcription models; you can still enter a model ID',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Subtitles online model'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'openai/whisper-large-v3');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      store.config?.onlineModelFor(RecognitionPurpose.subtitle),
      'openai/whisper-large-v3',
    );
  });

  testWidgets('选择器标记当前模型，并保留手动输入入口', (tester) async {
    final catalog = _FakeCatalog()
      ..models = const ['openai/whisper-large-v3', 'openai/whisper-small'];
    final store = _InMemorySpeechConfigStore(
      config: _openRouterConfigWithModels,
      apiKey: 'sk-speech-sentinel-4b7d',
    );
    await tester.pumpWidget(app(store, catalog: catalog));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get transcription models'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Subtitles online model'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.text('Enter a model ID'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'openai/whisper-base');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      store.config?.onlineModelFor(RecognitionPurpose.subtitle),
      'openai/whisper-base',
    );
  });

  testWidgets('模型选择器限制高度，长目录在弹层内部滚动', (tester) async {
    final catalog = _FakeCatalog()
      ..models = [
        for (var i = 0; i < 30; i++) 'openai/whisper-model-$i',
      ];
    final store = _InMemorySpeechConfigStore(
      config: _openRouterConfigWithModels,
      apiKey: 'sk-speech-sentinel-4b7d',
    );
    await tester.pumpWidget(app(store, catalog: catalog));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get transcription models'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Subtitles online model'));
    await tester.pumpAndSettle();

    final screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final sheet = tester.getSize(find.byType(BottomSheet));
    expect(sheet.height, lessThan(screenHeight * 0.75));
    expect(find.text('Enter a model ID'), findsOneWidget);
  });

  testWidgets('获取目录只读：不发验证请求，不写能力记录', (tester) async {
    final catalog = _FakeCatalog()..models = const ['openai/whisper-large-v3'];
    final capabilityStore = _InMemoryCapabilityStore();
    final probe = _FakeProbe();
    await tester.pumpWidget(
      app(
        _InMemorySpeechConfigStore(
          config: _openRouterConfig,
          apiKey: 'sk-speech-sentinel-4b7d',
        ),
        capabilityStore: capabilityStore,
        probe: probe,
        catalog: catalog,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get transcription models'));
    await tester.pumpAndSettle();

    expect(catalog.callCount, 1);
    expect(probe.runCount, 0);
    expect(capabilityStore.records, isEmpty);
  });

  testWidgets('根地址变化后清空列表，模型行回到手填', (tester) async {
    final catalog = _FakeCatalog()..models = const ['openai/whisper-large-v3'];
    final store = _InMemorySpeechConfigStore(
      config: _openRouterConfig,
      apiKey: 'sk-speech-sentinel-4b7d',
    );
    await tester.pumpWidget(app(store, catalog: catalog));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get transcription models'));
    await tester.pumpAndSettle();
    expect(find.text('1 transcription models retrieved'), findsOneWidget);

    await tester.tap(find.text('Base URL'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://speech.example.com/v1',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('1 transcription models retrieved'), findsNothing);

    await tester.tap(find.text('Subtitles online model'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('API Key 变化后清空列表', (tester) async {
    final catalog = _FakeCatalog()..models = const ['openai/whisper-large-v3'];
    final store = _InMemorySpeechConfigStore(
      config: _openRouterConfig,
      apiKey: 'sk-speech-sentinel-4b7d',
    );
    await tester.pumpWidget(app(store, catalog: catalog));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get transcription models'));
    await tester.pumpAndSettle();
    expect(find.text('1 transcription models retrieved'), findsOneWidget);

    await tester.tap(find.text('API key'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'sk-rotated');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('1 transcription models retrieved'), findsNothing);
  });

  testWidgets('配置变化后迟到的目录结果被丢弃', (tester) async {
    final catalog = _FakeCatalog()..models = const ['openai/whisper-large-v3'];
    final pending = catalog.hold();
    final store = _InMemorySpeechConfigStore(
      config: _openRouterConfig,
      apiKey: 'sk-speech-sentinel-4b7d',
    );
    await tester.pumpWidget(app(store, catalog: catalog));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get transcription models'));
    await tester.pump();

    await tester.tap(find.text('Base URL'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://speech.example.com/v1',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    pending.complete();
    await tester.pumpAndSettle();

    expect(find.textContaining('transcription models retrieved'), findsNothing);
    expect(
      store.config?.onlineModelFor(RecognitionPurpose.subtitle),
      '',
      reason: '旧结果不能写进新配置',
    );

    await tester.tap(find.text('Subtitles online model'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('页面卸载后迟到的目录结果被丢弃', (tester) async {
    final catalog = _FakeCatalog()..models = const ['openai/whisper-large-v3'];
    final pending = catalog.hold();
    await tester.pumpWidget(
      app(
        _InMemorySpeechConfigStore(
          config: _openRouterConfig,
          apiKey: 'sk-speech-sentinel-4b7d',
        ),
        catalog: catalog,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get transcription models'));
    await tester.pump();

    // 卸载页面后请求才回来：不抛异常也不改状态。
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  group('改语音服务配置时处理在途任务', () {
    /// 记录取消动作的在途任务；[usesOnlineSpeech] 表示是否绑定语音服务配置。
    RecognitionInFlightTask inFlightTask(
      RecognitionPurpose purpose,
      List<RecognitionPurpose> cancelled, {
      bool usesOnlineSpeech = true,
    }) => RecognitionInFlightTask(
      purpose: purpose,
      label: purpose.name,
      usesOnlineSpeech: usesOnlineSpeech,
      onCancel: () async => cancelled.add(purpose),
    );

    testWidgets('改某用途在线模型时告知，拒绝则保留配置与在途任务', (tester) async {
      final cancelled = <RecognitionPurpose>[];
      final registry = RecognitionInFlightRegistry();
      final task = inFlightTask(RecognitionPurpose.subtitle, cancelled);
      registry.register(task);
      final store = _InMemorySpeechConfigStore(
        config: _openRouterConfigWithModels,
        apiKey: 'sk-speech-sentinel-4b7d',
      );
      await tester.pumpWidget(app(store, inFlightRegistry: registry));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Subtitles online model'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'openai/whisper-large-v3-new',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Change recognition settings?'), findsOneWidget);
      expect(
        find.textContaining('Running recognition tasks affected: 1'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(
        store.config?.onlineModelFor(RecognitionPurpose.subtitle),
        'openai/whisper-large-v3',
      );
      expect(cancelled, isEmpty);
      expect(task.isCancelled, isFalse);
      expect(registry.pendingFor(RecognitionPurpose.subtitle), [task]);
    });

    testWidgets('接受后取消受影响任务并保存，无关用途不受影响', (tester) async {
      final cancelled = <RecognitionPurpose>[];
      final registry = RecognitionInFlightRegistry();
      final subtitleTask = inFlightTask(RecognitionPurpose.subtitle, cancelled);
      final shadowingTask = inFlightTask(
        RecognitionPurpose.shadowing,
        cancelled,
      );
      registry.register(subtitleTask);
      registry.register(shadowingTask);
      final store = _InMemorySpeechConfigStore(
        config: _openRouterConfigWithModels,
        apiKey: 'sk-speech-sentinel-4b7d',
      );
      await tester.pumpWidget(app(store, inFlightRegistry: registry));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Subtitles online model'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'openai/whisper-large-v3-new',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel tasks and change'));
      await tester.pumpAndSettle();

      expect(
        store.config?.onlineModelFor(RecognitionPurpose.subtitle),
        'openai/whisper-large-v3-new',
      );
      expect(
        store.config?.onlineModelFor(RecognitionPurpose.shadowing),
        'openai/whisper-large-v3',
        reason: '只改字幕模型，其它用途的在线模型保持不变',
      );
      expect(cancelled, [RecognitionPurpose.subtitle]);
      expect(shadowingTask.isCancelled, isFalse);
      expect(registry.pendingFor(RecognitionPurpose.shadowing), [
        shadowingTask,
      ]);
    });

    testWidgets('改服务地址影响全部在线任务，本机任务不受影响', (tester) async {
      final cancelled = <RecognitionPurpose>[];
      final registry = RecognitionInFlightRegistry();
      final retellOnlineTask = inFlightTask(
        RecognitionPurpose.retell,
        cancelled,
      );
      final localSubtitleTask = inFlightTask(
        RecognitionPurpose.subtitle,
        cancelled,
        usesOnlineSpeech: false,
      );
      registry.register(retellOnlineTask);
      registry.register(localSubtitleTask);
      final store = _InMemorySpeechConfigStore(
        config: _openRouterConfigWithModels,
        apiKey: 'sk-speech-sentinel-4b7d',
      );
      await tester.pumpWidget(app(store, inFlightRegistry: registry));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Base URL'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'https://speech.example.com/v1',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Running recognition tasks affected: 1'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel tasks and change'));
      await tester.pumpAndSettle();

      expect(store.config?.baseUrl, 'https://speech.example.com/v1');
      expect(cancelled, [RecognitionPurpose.retell]);
      expect(localSubtitleTask.isCancelled, isFalse);
    });
  });

  testWidgets('首次验证前告知上传目标、下游供应商与可能收费，取消则不发请求', (tester) async {
    final probe = _FakeProbe()
      ..capability = _capability(
        modelId: 'openai/whisper-large-v3',
        segments: true,
        words: true,
      );
    await tester.pumpWidget(
      app(
        _InMemorySpeechConfigStore(
          config: _openRouterConfigWithModels,
          apiKey: 'sk-speech-sentinel-4b7d',
        ),
        capabilityStore: _InMemoryCapabilityStore(),
        probe: probe,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Verify model').first);
    await tester.pumpAndSettle();

    expect(find.text('Send a test sample?'), findsOneWidget);
    expect(find.textContaining('openrouter.ai'), findsWidgets);
    expect(
      find.textContaining('OpenRouter and the downstream providers'),
      findsOneWidget,
    );
    expect(find.textContaining('charge your account'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(probe.runCount, 0);
  });

  testWidgets('确认告知后只发一次请求，分别显示字幕与词能力，同一服务不再重复告知', (tester) async {
    final probe = _FakeProbe()
      ..capability = _capability(
        modelId: 'openai/whisper-large-v3',
        segments: true,
        words: true,
        cost: 0.0004,
      );
    final capabilityStore = _InMemoryCapabilityStore();
    await tester.pumpWidget(
      app(
        _InMemorySpeechConfigStore(
          config: _openRouterConfigWithModels,
          apiKey: 'sk-speech-sentinel-4b7d',
        ),
        capabilityStore: capabilityStore,
        probe: probe,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Verify model').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send test'));
    await tester.pumpAndSettle();

    expect(probe.runCount, 1);
    expect(
      find.textContaining('Subtitles available · Word timestamps available'),
      findsWidgets,
    );
    expect(
      find.textContaining('Provider-reported cost: 0.0004'),
      findsOneWidget,
    );

    // 同一服务已确认：再验证时不重复告知，但仍可手动重测。
    await tester.tap(find.text('Verify model').first);
    await tester.pumpAndSettle();

    expect(find.text('Send a test sample?'), findsNothing);
    expect(probe.runCount, 2);
  });

  testWidgets('只有文本没有合法片段时显示仅文本可用', (tester) async {
    final capabilityStore = _InMemoryCapabilityStore();
    capabilityStore.records[_capability(
      modelId: 'openai/whisper-large-v3',
      segments: false,
    ).identity] = _capability(
      modelId: 'openai/whisper-large-v3',
      segments: false,
    );
    await tester.pumpWidget(
      app(
        _InMemorySpeechConfigStore(
          config: _openRouterConfigWithModels,
          apiKey: 'sk-speech-sentinel-4b7d',
        ),
        capabilityStore: capabilityStore,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Text only, no usable segments'), findsWidgets);
    expect(find.textContaining('Subtitles available'), findsNothing);
  });

  testWidgets('验证失败显示可分类原因，状态不变成已验证', (tester) async {
    final capabilityStore = _InMemoryCapabilityStore()
      ..notices.add(_openRouterConfigWithModels.baseUrl);
    final probe = _FakeProbe()
      ..failure = const SpeechTranscriptionException(
        SpeechTranscriptionErrorKind.insufficientBalance,
      );
    await tester.pumpWidget(
      app(
        _InMemorySpeechConfigStore(
          config: _openRouterConfigWithModels,
          apiKey: 'sk-speech-sentinel-4b7d',
        ),
        capabilityStore: capabilityStore,
        probe: probe,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Verify model').first);
    await tester.pumpAndSettle();

    expect(
      find.text('Provider balance or plan is insufficient'),
      findsOneWidget,
    );
    expect(find.text('Saved, not verified'), findsOneWidget);
  });

  testWidgets('供应商未报告费用时标注未知而不是零，并显示已验证', (tester) async {
    final capabilityStore = _InMemoryCapabilityStore()
      ..notices.add(_openRouterConfigWithModels.baseUrl);
    final probe = _FakeProbe()
      ..capability = _capability(
        modelId: 'openai/whisper-large-v3',
        segments: false,
      );
    await tester.pumpWidget(
      app(
        _InMemorySpeechConfigStore(
          config: _openRouterConfigWithModels,
          apiKey: 'sk-speech-sentinel-4b7d',
        ),
        capabilityStore: capabilityStore,
        probe: probe,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Verify model').first);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Verified. The provider reported no cost, so the charge is unknown',
      ),
      findsOneWidget,
    );
    expect(find.text('Saved and verified'), findsOneWidget);
  });
}
