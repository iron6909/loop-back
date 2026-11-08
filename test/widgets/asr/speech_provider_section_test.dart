/// 在线语音服务配置区：状态显示、能力验证与上传告知。
library;

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

  @override
  Future<List<String>> fetchTranscriptionModels({
    required SpeechConfig config,
    required String apiKey,
    CancelToken? cancelToken,
  }) async {
    callCount++;
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

  testWidgets('OpenRouter 可刷新转写目录并选用模型', (tester) async {
    final store = _InMemorySpeechConfigStore(
      config: _openRouterConfig,
      apiKey: 'sk-speech-sentinel-4b7d',
    );
    final catalog = _FakeCatalog()..models = const ['openai/whisper-large-v3'];
    await tester.pumpWidget(app(store, catalog: catalog));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Refresh transcription models').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('openai/whisper-large-v3'));
    await tester.pumpAndSettle();

    expect(catalog.callCount, 1);
    expect(
      store.config?.onlineModelFor(RecognitionPurpose.subtitle),
      'openai/whisper-large-v3',
    );
  });

  testWidgets('自定义服务不提供目录刷新，但手填仍可用', (tester) async {
    final store = _InMemorySpeechConfigStore(
      config: const SpeechConfig(
        kind: SpeechProviderKind.custom,
        baseUrl: 'https://speech.example.com/stt',
      ),
      apiKey: 'sk-speech-sentinel-4b7d',
    );
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Refresh transcription models'), findsNothing);

    await tester.tap(find.text('Shadowing online model'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'whisper-1');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      store.config?.onlineModelFor(RecognitionPurpose.shadowing),
      'whisper-1',
    );
  });

  testWidgets('目录刷新失败时提示，手填不受影响', (tester) async {
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

    await tester.tap(find.byTooltip('Refresh transcription models').first);
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
