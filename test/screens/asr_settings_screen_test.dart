import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_loop/l10n/app_localizations.dart';
import 'package:echo_loop/providers/offline_asr_settings_provider.dart';
import 'package:echo_loop/screens/asr_settings_screen.dart';
import 'package:echo_loop/services/asr/asr_model_manager.dart';
import 'package:echo_loop/services/asr/offline_asr_engine.dart';
import 'package:echo_loop/theme/app_theme.dart';

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

Widget _buildTestWidget(_StaticOfflineAsrSettingsNotifier notifier) {
  return ProviderScope(
    overrides: [offlineAsrSettingsProvider.overrideWith(() => notifier)],
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

void main() {
  const recommendedModel = AsrModelInfo(
    id: 'whisper-base-en-int8',
    displayName: 'Whisper Base.en',
    type: AsrModelType.whisper,
  );

  testWidgets('残缺模型显示失败状态和模型档位', (tester) async {
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
    // 引擎卡片 + 模型列表卡片 + 下载来源卡片。
    expect(find.byType(Card), findsNWidgets(3));
    expect(find.textContaining('~99 MB'), findsOneWidget);
    expect(find.textContaining('~150 MB'), findsOneWidget);
    expect(find.textContaining('~360 MB'), findsOneWidget);
  });

  testWidgets('Apple Speech 后端不平铺模型列表', (tester) async {
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
    // 仅已迁移的 Tiny 展示公开来源与许可；Base/Small 不冒充公开源。
    expect(find.textContaining('Source: Hugging Face'), findsOneWidget);
    expect(find.textContaining('License: MIT'), findsOneWidget);
    // 来源选项只出现在下载来源卡片中。
    expect(find.text('hf-mirror.com (mirror)'), findsOneWidget);

    await tester.tap(find.text('hf-mirror.com (mirror)'));
    await tester.pumpAndSettle();

    expect(notifier.downloadSourceChanges, [
      AsrDownloadSource.huggingFaceMirror,
    ]);
  });
}
