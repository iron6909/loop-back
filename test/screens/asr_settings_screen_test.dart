import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/providers/shared_preferences_provider.dart';
import 'package:loop_back/l10n/app_localizations.dart';
import 'package:loop_back/models/recognition_selection.dart';
import 'package:loop_back/providers/offline_asr_settings_provider.dart';
import 'package:loop_back/providers/speech_capability_provider.dart';
import 'package:loop_back/providers/speech_configuration_provider.dart';
import 'package:loop_back/screens/asr_settings_screen.dart';
import 'package:loop_back/services/speech/speech_capability.dart';
import 'package:loop_back/services/speech/speech_config.dart';
import 'package:loop_back/services/speech/speech_config_store.dart';
import 'package:loop_back/services/asr/asr_model_manager.dart';
import 'package:loop_back/services/asr/offline_asr_engine.dart';
import 'package:loop_back/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 只保存在内存里的在线语音服务配置：本页测试只关心入口状态，不触发真实存储。
class _StaticSpeechConfigStore extends SpeechConfigStore {
  _StaticSpeechConfigStore({this.config, this.apiKey});

  final SpeechConfig? config;
  final String? apiKey;

  @override
  Future<SpeechConfig?> read() async => config;

  @override
  Future<String?> readApiKey() async => apiKey;

  @override
  Future<String?> readCredentialVersion() async => 'test-credential-version';
}

/// 只记录调用的离线 ASR 设置：不下载、不初始化引擎，也不需要真实偏好写入。
class _StaticOfflineAsrSettingsNotifier extends OfflineAsrSettingsNotifier {
  _StaticOfflineAsrSettingsNotifier(this._initialState);

  final OfflineAsrSettingsState _initialState;
  bool deleteAllDownloadedModelsCalled = false;
  bool? deleteAllIncludeSelected;
  final downloadedModelIds = <String>[];
  final selectedModelIds = <String>[];
  final backends = <AsrBackend>[];
  final retriedModelIds = <String>[];
  final cancelledModelIds = <String>[];
  final deletedModelIds = <String>[];

  @override
  OfflineAsrSettingsState build() => _initialState;

  @override
  Future<void> downloadModel(String modelId) async {
    downloadedModelIds.add(modelId);
  }

  @override
  Future<void> selectModel(AsrModelInfo model) async {
    selectedModelIds.add(model.id);
  }

  @override
  Future<void> setBackend(AsrBackend backend) async {
    backends.add(backend);
  }

  @override
  Future<void> retryDownload([String? modelId]) async {
    retriedModelIds.add(modelId ?? state.selectedModel.id);
  }

  @override
  Future<void> cancelDownload([String? modelId]) async {
    cancelledModelIds.add(modelId ?? state.selectedModel.id);
  }

  @override
  Future<void> deleteModel([String? modelId]) async {
    deletedModelIds.add(modelId ?? state.selectedModel.id);
  }

  @override
  Future<void> deleteDownloadedModels({required bool includeSelected}) async {
    deleteAllDownloadedModelsCalled = true;
    deleteAllIncludeSelected = includeSelected;
  }
}

/// 只保存在内存里的能力记录：入口状态测试不读取真实偏好。
class _StaticCapabilityStore extends SpeechCapabilityStore {
  _StaticCapabilityStore(this.records);

  final Map<String, SpeechCapability> records;

  @override
  Future<Map<String, SpeechCapability>> readAll() async => records;

  @override
  Future<SpeechCapability?> read(String identity) async => records[identity];
}

Widget _buildTestWidget(
  _StaticOfflineAsrSettingsNotifier notifier, {
  SpeechConfigStore? speechStore,
  SpeechCapabilityStore? capabilityStore,
}) {
  return ProviderScope(
    overrides: [
      offlineAsrSettingsProvider.overrideWith(() => notifier),
      sharedPreferencesProvider.overrideWithValue(_prefs),
      speechConfigStoreProvider.overrideWithValue(
        speechStore ?? _StaticSpeechConfigStore(),
      ),
      if (capabilityStore != null)
        speechCapabilityStoreProvider.overrideWithValue(capabilityStore),
    ],
    child: MaterialApp(
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light(),
      home: const AsrSettingsScreen(),
    ),
  );
}

/// 识别设置页读取的偏好（每个用例在 setUp 里重置）。
late SharedPreferences _prefs;

/// 改写识别偏好；必须在创建测试组件前调用，页面首个 provider 读取就确定选择。
Future<void> _usePrefs(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  _prefs = await SharedPreferences.getInstance();
}

/// 资源库行与底部来源选项会撑高整页，断言整页内容的用例改用更高的视口，
/// 避免只挂载视口内的组件。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  const recommendedModel = AsrModelInfo(
    id: 'whisper-base-en-int8',
    displayName: 'Whisper Base.en',
    type: AsrModelType.whisper,
  );

  OfflineAsrSettingsState stateWith({
    AsrBackend backend = AsrBackend.platform,
    Map<String, AsrModelState> modelStates = const {},
  }) => OfflineAsrSettingsState(
    enabled: true,
    backend: backend,
    recommendedModel: recommendedModel,
    modelStates: modelStates,
  );

  testWidgets('残缺模型显示失败状态与修复动作', (tester) async {
    _useTallViewport(tester);
    final notifier = _StaticOfflineAsrSettingsNotifier(
      OfflineAsrSettingsState(
        enabled: true,
        backend: AsrBackend.offline,
        downloadStatus: AsrModelDownloadStatus.failed,
        localSizeBytes: 153 * 1024 * 1024,
        recommendedModel: recommendedModel,
      ),
    );

    await tester.pumpWidget(_buildTestWidget(notifier));
    await tester.pumpAndSettle();

    // 显示真实模型名称
    expect(find.textContaining('Whisper Base (English)'), findsAny);
    // 不显示 Ready（下载失败）
    expect(find.textContaining('Ready'), findsNothing);
    // 失败保留已下载内容，并提供重试（重新下载即修复）
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('153 MB'), findsAny);
  });

  testWidgets('不再显示语音识别总开关，关闭旧状态也显示模型列表', (tester) async {
    final notifier = _StaticOfflineAsrSettingsNotifier(
      OfflineAsrSettingsState(
        enabled: false,
        backend: AsrBackend.offline,
        localSizeBytes: 153 * 1024 * 1024,
        recommendedModel: recommendedModel,
      ),
    );

    await tester.pumpWidget(_buildTestWidget(notifier));
    await tester.pumpAndSettle();

    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('Disabled'), findsNothing);
    expect(find.textContaining('Whisper Base (English)'), findsAny);
  });

  testWidgets('已下载模型显示 Ready 和大小', (tester) async {
    _useTallViewport(tester);
    final notifier = _StaticOfflineAsrSettingsNotifier(
      stateWith(
        backend: AsrBackend.offline,
        modelStates: const {
          'whisper-base-en-int8': AsrModelState(
            downloadStatus: AsrModelDownloadStatus.downloaded,
            localSizeBytes: 153 * 1024 * 1024,
          ),
        },
      ),
    );

    await tester.pumpWidget(_buildTestWidget(notifier));
    await tester.pumpAndSettle();

    expect(find.textContaining('Whisper Base (English)'), findsAny);
    expect(find.textContaining('Ready'), findsAny);
    expect(find.textContaining('153 MB'), findsAny);
  });

  testWidgets('取消下载仅显示在未选中的下载模型上', (tester) async {
    _useTallViewport(tester);
    const selectedId = 'whisper-base-en-int8';
    const otherId = 'whisper-tiny-en-int8';
    final notifier = _StaticOfflineAsrSettingsNotifier(
      OfflineAsrSettingsState(
        enabled: true,
        backend: AsrBackend.offline,
        selectedModel: const AsrModelInfo(
          id: selectedId,
          displayName: 'Whisper Base.en',
          type: AsrModelType.whisper,
        ),
        recommendedModel: recommendedModel,
        modelStates: const {
          selectedId: AsrModelState(
            downloadStatus: AsrModelDownloadStatus.downloading,
            downloadProgress: 0.4,
          ),
          otherId: AsrModelState(
            downloadStatus: AsrModelDownloadStatus.downloading,
            downloadProgress: 0.2,
          ),
        },
      ),
    );

    await tester.pumpWidget(_buildTestWidget(notifier));
    await tester.pumpAndSettle();

    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(notifier.cancelledModelIds, [otherId]);
  });

  testWidgets('识别方式分组列出三个用途与各自状态，说明文字只有一条', (tester) async {
    _useTallViewport(tester);
    final notifier = _StaticOfflineAsrSettingsNotifier(
      stateWith(backend: AsrBackend.offline),
    );

    await tester.pumpWidget(_buildTestWidget(notifier));
    await tester.pumpAndSettle();

    expect(find.text('Recognition modes'), findsOneWidget);
    expect(find.text('Subtitles'), findsOneWidget);
    expect(find.text('Shadowing'), findsOneWidget);
    expect(find.text('Retelling'), findsOneWidget);
    // 三档都未安装：本机状态直接说明缺什么。
    expect(find.text('Not downloaded'), findsNWidgets(3));
    // 说明文字只保留一条，位于「识别方式」之前。
    expect(
      find.text(
        'Subtitles, shadowing, and retelling each keep their own recognition '
        'mode and model.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('页面不再出现语音引擎卡片与后端单选，分组顺序为识别方式、本机模型、在线服务', (tester) async {
    _useTallViewport(tester);
    final notifier = _StaticOfflineAsrSettingsNotifier(stateWith());

    await tester.pumpWidget(_buildTestWidget(notifier));
    await tester.pumpAndSettle();

    expect(find.text('Speech Engine'), findsNothing);
    expect(find.text('Apple AI'), findsNothing);
    expect(find.byType(RadioListTile<AsrBackend>), findsNothing);

    final recognitionTop = tester.getTopLeft(find.text('Recognition modes')).dy;
    final libraryTop = tester.getTopLeft(find.text('On-device models')).dy;
    final onlineSectionTop = tester.getTopLeft(find.text('Online service')).dy;
    final onlineTop = tester.getTopLeft(find.text('Online speech service')).dy;
    expect(recognitionTop, lessThan(libraryTop));
    expect(libraryTop, lessThan(onlineSectionTop));
    expect(onlineSectionTop, lessThan(onlineTop));
  });

  testWidgets('跟读使用系统识别时本机模型资源库仍可见，下载只装模型不改跟读选择', (tester) async {
    _useTallViewport(tester);
    final notifier = _StaticOfflineAsrSettingsNotifier(stateWith());

    await tester.pumpWidget(_buildTestWidget(notifier));
    await tester.pumpAndSettle();

    expect(find.text('On-device models'), findsOneWidget);
    expect(find.text('Whisper Tiny (English)'), findsOneWidget);
    expect(find.text('Whisper Base (English)'), findsOneWidget);
    expect(find.text('Whisper Small (English)'), findsOneWidget);
    // 三档都未安装：各有一行下载入口。
    expect(find.text('Download'), findsNWidgets(3));

    await tester.tap(find.text('Download').first);
    await tester.pumpAndSettle();

    expect(notifier.downloadedModelIds, ['whisper-tiny-en-int8']);
    expect(notifier.selectedModelIds, isEmpty, reason: '资源库不是模型选择入口');
    expect(notifier.backends, isEmpty, reason: '下载不改写跟读后端');
  });

  testWidgets('每行显示推荐标记、大小、下载状态与用途标签，标签只标记本机用途', (tester) async {
    _useTallViewport(tester);
    // 字幕与复述都用本机 Small；跟读沿用系统识别，不占用本机模型。
    await _usePrefs({
      'local_transcription_model_id': 'whisper-small-en-int8',
      'recognition_retell_model_id': 'whisper-small-en-int8',
      'offline_asr_backend': AsrBackend.platform.name,
    });
    final notifier = _StaticOfflineAsrSettingsNotifier(
      stateWith(
        modelStates: const {
          'whisper-small-en-int8': AsrModelState(
            downloadStatus: AsrModelDownloadStatus.downloaded,
            localSizeBytes: 358 * 1024 * 1024,
          ),
        },
      ),
    );

    await tester.pumpWidget(_buildTestWidget(notifier));
    await tester.pumpAndSettle();

    expect(find.text('Recommended'), findsOneWidget);
    expect(find.text('Ready · 358 MB'), findsOneWidget);
    expect(find.text('Subtitles in use'), findsOneWidget);
    expect(find.text('Retelling in use'), findsOneWidget);
    expect(find.text('Shadowing in use'), findsNothing);
    expect(find.textContaining('~99 MB'), findsOneWidget);
    expect(find.textContaining('~153 MB'), findsOneWidget);
  });

  testWidgets('已下载模型可删除，跟读当前档位不提供删除入口', (tester) async {
    _useTallViewport(tester);
    final notifier = _StaticOfflineAsrSettingsNotifier(
      stateWith(
        backend: AsrBackend.offline,
        modelStates: const {
          'whisper-base-en-int8': AsrModelState(
            downloadStatus: AsrModelDownloadStatus.downloaded,
            localSizeBytes: 153 * 1024 * 1024,
          ),
          'whisper-small-en-int8': AsrModelState(
            downloadStatus: AsrModelDownloadStatus.downloaded,
            localSizeBytes: 358 * 1024 * 1024,
          ),
        },
      ),
    );

    await tester.pumpWidget(_buildTestWidget(notifier));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Delete Model'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete Model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete Model').last);
    await tester.pumpAndSettle();

    expect(notifier.deletedModelIds, ['whisper-small-en-int8']);
  });

  testWidgets('系统后端下跟读当前档位也可删除，与本机后端的删除保护不同', (tester) async {
    _useTallViewport(tester);
    final notifier = _StaticOfflineAsrSettingsNotifier(
      stateWith(
        backend: AsrBackend.platform,
        modelStates: const {
          'whisper-base-en-int8': AsrModelState(
            downloadStatus: AsrModelDownloadStatus.downloaded,
            localSizeBytes: 153 * 1024 * 1024,
          ),
        },
      ),
    );

    await tester.pumpWidget(_buildTestWidget(notifier));
    await tester.pumpAndSettle();

    // 系统识别不依赖本机模型：跟读档位只是下载状态，删掉与本机清理规则一致。
    expect(find.byTooltip('Delete Model'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete Model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete Model').last);
    await tester.pumpAndSettle();

    expect(notifier.deletedModelIds, ['whisper-base-en-int8']);
  });

  testWidgets('分组标题显示已下载总占用，清理沿用现有确认与保护规则', (tester) async {
    _useTallViewport(tester);
    final notifier = _StaticOfflineAsrSettingsNotifier(
      stateWith(
        backend: AsrBackend.offline,
        modelStates: const {
          'whisper-base-en-int8': AsrModelState(
            downloadStatus: AsrModelDownloadStatus.downloaded,
            localSizeBytes: 153 * 1024 * 1024,
          ),
          'whisper-small-en-int8': AsrModelState(
            downloadStatus: AsrModelDownloadStatus.downloaded,
            localSizeBytes: 358 * 1024 * 1024,
          ),
        },
      ),
    );

    await tester.pumpWidget(_buildTestWidget(notifier));
    await tester.pumpAndSettle();

    expect(find.text('Downloaded 511 MB'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete all downloaded models'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Delete all downloaded LoopBack speech recognition models? You can '
        're-download them anytime.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Delete Model').last);
    await tester.pumpAndSettle();

    expect(notifier.deleteAllDownloadedModelsCalled, isTrue);
    expect(
      notifier.deleteAllIncludeSelected,
      isTrue,
      reason: '当前使用中的档位仍由删除规则保护',
    );
  });

  testWidgets('已迁移模型显示真实名称、来源与许可，来源选项只影响未安装下载', (tester) async {
    _useTallViewport(tester);
    final notifier = _StaticOfflineAsrSettingsNotifier(stateWith());

    await tester.pumpWidget(_buildTestWidget(notifier));
    await tester.pumpAndSettle();

    // 三档模型都显示真实 Whisper 名称与英语。
    expect(find.text('Whisper Tiny (English)'), findsOneWidget);
    expect(find.text('Whisper Base (English)'), findsOneWidget);
    expect(find.text('Whisper Small (English)'), findsOneWidget);
    // 三档都已迁移到固定公开来源，都展示来源与许可。
    expect(find.textContaining('Source: Hugging Face'), findsNWidgets(3));
    expect(find.textContaining('License: MIT'), findsNWidgets(3));
    // 不再提供手选来源：页面上没有来源入口与镜像选项。
    expect(find.text('Model Source'), findsNothing);
    expect(find.text('hf-mirror.com (mirror)'), findsNothing);
  });

  group('在线语音服务入口', () {
    _StaticOfflineAsrSettingsNotifier notifier() =>
        _StaticOfflineAsrSettingsNotifier(stateWith());

    testWidgets('未配置时入口显示未配置状态，主页面不再内嵌配置表单', (tester) async {
      _useTallViewport(tester);

      await tester.pumpWidget(_buildTestWidget(notifier()));
      await tester.pumpAndSettle();

      expect(find.text('Online speech service'), findsOneWidget);
      expect(find.text('Not configured'), findsOneWidget);
      // 主页面只保留入口行：供应商、地址、Key 与逐用途在线模型都在独立页。
      expect(find.text('Provider'), findsNothing);
      expect(find.text('Base URL'), findsNothing);
      expect(find.text('API key'), findsNothing);
      expect(find.text('Subtitles online model'), findsNothing);
      expect(find.text('Verify model'), findsNothing);
    });

    testWidgets('缺 Key 时入口显示缺少 Key 与服务类型', (tester) async {
      _useTallViewport(tester);

      await tester.pumpWidget(
        _buildTestWidget(
          notifier(),
          speechStore: _StaticSpeechConfigStore(
            config: const SpeechConfig(
              kind: SpeechProviderKind.openrouter,
              baseUrl: 'https://openrouter.ai/api/v1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('API key missing'), findsOneWidget);
      expect(find.text('OpenRouter'), findsOneWidget);
    });

    testWidgets('配置与 Key 齐备时入口显示已保存未验证', (tester) async {
      _useTallViewport(tester);

      await tester.pumpWidget(
        _buildTestWidget(
          notifier(),
          speechStore: _StaticSpeechConfigStore(
            config: const SpeechConfig(
              kind: SpeechProviderKind.openrouter,
              baseUrl: 'https://openrouter.ai/api/v1',
            ),
            apiKey: 'spk-4b7d',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Saved, not verified'), findsOneWidget);
      expect(find.text('OpenRouter'), findsOneWidget);
    });

    testWidgets('配置与 Key 齐备且已验证时入口显示已保存已验证', (tester) async {
      _useTallViewport(tester);
      const config = SpeechConfig(
        kind: SpeechProviderKind.openrouter,
        baseUrl: 'https://openrouter.ai/api/v1',
        onlineModels: {RecognitionPurpose.shadowing: 'openai/whisper-large-v3'},
      );
      final capability = SpeechCapability(
        identity: SpeechCapability.identityFor(
          kind: SpeechProviderKind.openrouter,
          baseUrl: config.baseUrl,
          modelId: 'openai/whisper-large-v3',
          credentialVersion: 'test-credential-version',
        ),
        text: true,
        segments: true,
        wordTimestamps: false,
        validatedAt: DateTime.utc(2026, 11, 8),
      );

      await tester.pumpWidget(
        _buildTestWidget(
          notifier(),
          speechStore: _StaticSpeechConfigStore(
            config: config,
            apiKey: 'spk-4b7d',
          ),
          capabilityStore: _StaticCapabilityStore({
            capability.identity: capability,
          }),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Saved and verified'), findsOneWidget);
    });

    testWidgets('点击入口进入在线语音服务页，返回后回到语音识别页', (tester) async {
      _useTallViewport(tester);

      await tester.pumpWidget(_buildTestWidget(notifier()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Online speech service'));
      await tester.pumpAndSettle();

      // 独立页：标题、说明与连接配置都在这一页。
      expect(find.text('Online speech service'), findsOneWidget);
      expect(
        find.textContaining('share one service address and key'),
        findsOneWidget,
      );
      expect(find.text('Not configured'), findsOneWidget);
      expect(find.text('Provider'), findsOneWidget);
      expect(find.text('Base URL'), findsOneWidget);
      expect(find.text('Subtitles online model'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.text('Recognition modes'), findsOneWidget);
      expect(find.text('Provider'), findsNothing);
    });
  });
}
