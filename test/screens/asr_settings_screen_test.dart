import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_loop/features/onboarding_survey/providers/onboarding_survey_provider.dart';
import 'package:echo_loop/l10n/app_localizations.dart';
import 'package:echo_loop/providers/offline_asr_settings_provider.dart';
import 'package:echo_loop/providers/speech_configuration_provider.dart';
import 'package:echo_loop/screens/asr_settings_screen.dart';
import 'package:echo_loop/services/speech/speech_config.dart';
import 'package:echo_loop/services/speech/speech_config_store.dart';
import 'package:echo_loop/services/asr/asr_model_manager.dart';
import 'package:echo_loop/services/asr/offline_asr_engine.dart';
import 'package:echo_loop/theme/app_theme.dart';
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

class _StaticOfflineAsrSettingsNotifier extends OfflineAsrSettingsNotifier {
  _StaticOfflineAsrSettingsNotifier(this._initialState);

  final OfflineAsrSettingsState _initialState;
  bool deleteAllDownloadedModelsCalled = false;
  bool? deleteAllIncludeSelected;
  final downloadSourceChanges = <AsrDownloadSource>[];

  @override
  Future<void> setDownloadSource(AsrDownloadSource source) async {
    downloadSourceChanges.add(source);
  }

  @override
  OfflineAsrSettingsState build() => _initialState;

  @override
  Future<void> retryDownload([String? modelId]) async {}

  @override
  Future<void> deleteDownloadedModels({required bool includeSelected}) async {
    deleteAllDownloadedModelsCalled = true;
    deleteAllIncludeSelected = includeSelected;
  }
}

Widget _buildTestWidget(
  _StaticOfflineAsrSettingsNotifier notifier, {
  SpeechConfigStore? speechStore,
}) {
  return ProviderScope(
    overrides: [
      offlineAsrSettingsProvider.overrideWith(() => notifier),
      sharedPreferencesProvider.overrideWithValue(_prefs),
      speechConfigStoreProvider.overrideWithValue(
        speechStore ?? _StaticSpeechConfigStore(),
      ),
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

/// 用途卡片与在线语音服务卡片加入后整页超过默认 800 高视口，需要断言整页卡片与
/// 底部来源选项的用例改用更高的视口，避免只挂载视口内的组件。
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
      OfflineAsrSettingsState(
        enabled: true,
        backend: AsrBackend.offline,
        downloadStatus: AsrModelDownloadStatus.downloaded,
        localSizeBytes: 153 * 1024 * 1024,
        recommendedModel: recommendedModel,
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
  });

  testWidgets('本机 Whisper 模型列表单独成组并显示预估大小', (tester) async {
    _useTallViewport(tester);
    final notifier = _StaticOfflineAsrSettingsNotifier(
      OfflineAsrSettingsState(
        enabled: true,
        backend: AsrBackend.offline,
        recommendedModel: recommendedModel,
      ),
    );

    await tester.pumpWidget(_buildTestWidget(notifier));
    await tester.pumpAndSettle();

    expect(find.text('Speech Engine'), findsOneWidget);
    // iOS/macOS 额外显示后端选择器中的本机 Whisper；Linux CI 不显示平台后端选择器。
    final expectedLocalLabels = Platform.isIOS || Platform.isMacOS ? 2 : 1;
    expect(
      find.text('Whisper (on-device)'),
      findsNWidgets(expectedLocalLabels),
    );
    // 用途选择卡片 + 在线服务入口卡片 + 引擎卡片 + 模型列表卡片 + 下载来源卡片。
    expect(find.byType(Card), findsNWidgets(5));
    expect(find.textContaining('~99 MB'), findsOneWidget);
    expect(find.textContaining('~153 MB'), findsOneWidget);
    expect(find.textContaining('~358 MB'), findsOneWidget);
  });

  testWidgets('Apple Speech 后端不平铺模型列表', (tester) async {
    _useTallViewport(tester);
    final notifier = _StaticOfflineAsrSettingsNotifier(
      OfflineAsrSettingsState(
        enabled: true,
        backend: AsrBackend.platform,
        recommendedModel: recommendedModel,
      ),
    );

    await tester.pumpWidget(_buildTestWidget(notifier));
    await tester.pumpAndSettle();

    expect(find.text('Speech Engine'), findsOneWidget);
    expect(find.text('Whisper Tiny (English)'), findsNothing);
    expect(find.text('Whisper Base (English)'), findsNothing);
    expect(find.text('Whisper Small (English)'), findsNothing);
  });

  testWidgets('Apple Speech 后端允许删除所有已下载 Whisper 模型', (tester) async {
    _useTallViewport(tester);
    final notifier = _StaticOfflineAsrSettingsNotifier(
      OfflineAsrSettingsState(
        enabled: true,
        backend: AsrBackend.platform,
        recommendedModel: recommendedModel,
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

    expect(find.text('Downloaded speech recognition models'), findsOneWidget);
    expect(find.textContaining('153 MB'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete Model'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Delete all downloaded Echo Loop speech recognition models? You can re-download them anytime.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Delete Model').last);
    await tester.pumpAndSettle();

    expect(notifier.deleteAllDownloadedModelsCalled, isTrue);
    expect(notifier.deleteAllIncludeSelected, isTrue);
  });

  testWidgets('已迁移模型显示真实名称、来源与许可，来源选项只影响未安装下载', (tester) async {
    _useTallViewport(tester);
    final notifier = _StaticOfflineAsrSettingsNotifier(
      OfflineAsrSettingsState(
        enabled: true,
        backend: AsrBackend.offline,
        recommendedModel: recommendedModel,
      ),
    );

    await tester.pumpWidget(_buildTestWidget(notifier));
    await tester.pumpAndSettle();

    // 三档模型都显示真实 Whisper 名称与英语。
    expect(find.text('Whisper Tiny (English)'), findsOneWidget);
    expect(find.text('Whisper Base (English)'), findsOneWidget);
    expect(find.text('Whisper Small (English)'), findsOneWidget);
    // 三档都已迁移到固定公开来源，都展示来源与许可。
    expect(find.textContaining('Source: Hugging Face'), findsNWidgets(3));
    expect(find.textContaining('License: MIT'), findsNWidgets(3));
    // 来源选项只出现在下载来源卡片中。
    expect(find.text('hf-mirror.com (mirror)'), findsOneWidget);

    await tester.tap(find.text('hf-mirror.com (mirror)'));
    await tester.pumpAndSettle();

    expect(notifier.downloadSourceChanges, [
      AsrDownloadSource.huggingFaceMirror,
    ]);
  });

  group('在线语音服务入口', () {
    _StaticOfflineAsrSettingsNotifier notifier() =>
        _StaticOfflineAsrSettingsNotifier(
          OfflineAsrSettingsState(
            enabled: true,
            backend: AsrBackend.offline,
            recommendedModel: recommendedModel,
          ),
        );

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
            apiKey: 'sk-speech-sentinel-4b7d',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Saved, not verified'), findsOneWidget);
      expect(find.text('OpenRouter'), findsOneWidget);
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

      expect(find.text('Recognition by purpose'), findsOneWidget);
      expect(find.text('Provider'), findsNothing);
    });
  });
}
