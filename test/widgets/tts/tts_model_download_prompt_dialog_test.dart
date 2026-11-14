import 'package:loop_back/providers/tts/kokoro_model_provider.dart';
import 'package:loop_back/providers/tts/piper_model_provider.dart';
import 'package:loop_back/providers/tts/tts_settings_provider.dart';
import 'package:loop_back/l10n/app_localizations.dart';
import 'package:loop_back/services/tts/kokoro_model_manager.dart';
import 'package:loop_back/services/tts/tts_engine.dart';
import 'package:loop_back/widgets/tts/tts_model_download_prompt_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestKokoroNotifier extends KokoroModelNotifier {
  _TestKokoroNotifier(this._initial);

  final KokoroModelsState _initial;
  final List<KokoroModelVariant> ensured = [];
  final List<KokoroModelVariant> cancelled = [];

  @override
  KokoroModelsState build() => _initial;

  @override
  Future<void> ensureDownloaded(KokoroModelVariant variant) async {
    ensured.add(variant);
  }

  @override
  Future<void> cancelDownload(KokoroModelVariant variant) async {
    cancelled.add(variant);
  }
}

void main() {
  test('Kokoro 发音状态复用当前 Kokoro 全局下载进度', () {
    final container = ProviderContainer(
      overrides: [
        initialTtsSettingsProvider.overrideWithValue(
          const TtsSettings(engine: TtsEngineKind.kokoro),
        ),
        initialKokoroModelStateProvider.overrideWithValue(
          const KokoroModelsState({
            KokoroModelVariant.fp32: KokoroModelState(
              downloadStatus: AsrModelDownloadStatus.downloading,
              downloadProgress: 0.42,
            ),
          }),
        ),
      ],
    );
    addTearDown(container.dispose);

    final state = container.read(ttsPlaybackModelStateProvider);

    expect(state.engine, TtsEngineKind.kokoro);
    expect(state.status, AsrModelDownloadStatus.downloading);
    expect(state.progress, 0.42);
    expect(state.estimatedDownloadBytes, 362749051);
    expect(state.isReady, isFalse);
  });

  test('Piper 发音状态复用当前 Piper 全局失败状态', () {
    const voiceId = 'en_US-kristin-medium';
    final container = ProviderContainer(
      overrides: [
        initialTtsSettingsProvider.overrideWithValue(
          const TtsSettings(engine: TtsEngineKind.piper),
        ),
        initialPiperModelStateProvider.overrideWithValue(
          const PiperModelsState({
            voiceId: PiperModelState(
              downloadStatus: AsrModelDownloadStatus.failed,
            ),
          }),
        ),
      ],
    );
    addTearDown(container.dispose);

    final state = container.read(ttsPlaybackModelStateProvider);

    expect(state.engine, TtsEngineKind.piper);
    expect(state.status, AsrModelDownloadStatus.failed);
    expect(state.isReady, isFalse);
    // HF 逐文件音色的预估包含共享 espeak 依赖（约 9MB）。
    expect(state.estimatedDownloadBytes, 72519295);
  });

  testWidgets('未下载时显示说明、预计流量和手动下载按钮', (tester) async {
    final notifier = _TestKokoroNotifier(const KokoroModelsState({}));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialTtsSettingsProvider.overrideWithValue(
            const TtsSettings(engine: TtsEngineKind.kokoro),
          ),
          kokoroModelProvider.overrideWith(() => notifier),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: TtsModelDownloadDialog(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Speech Synthesis Model Required'), findsOneWidget);
    expect(find.text('Estimated download: ~345.9 MB'), findsOneWidget);
    expect(
      find.text('You can also choose another speech model in Settings.'),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Download model'), findsOneWidget);
    expect(notifier.ensured, isEmpty);

    await tester.tap(find.text('Download model'));
    await tester.pump();
    expect(notifier.ensured, [KokoroModelVariant.fp32]);
  });

  testWidgets('下载中显示进度并可取消模型下载', (tester) async {
    final notifier = _TestKokoroNotifier(
      const KokoroModelsState({
        KokoroModelVariant.fp32: KokoroModelState(
          downloadStatus: AsrModelDownloadStatus.downloading,
          downloadProgress: 0.42,
        ),
      }),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialTtsSettingsProvider.overrideWithValue(
            const TtsSettings(engine: TtsEngineKind.kokoro),
          ),
          kokoroModelProvider.overrideWith(() => notifier),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: TtsModelDownloadDialog(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Downloading Speech Synthesis Model'), findsOneWidget);
    expect(find.text('Estimated download: ~345.9 MB'), findsOneWidget);
    expect(find.text('42% complete'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Cancel Download'), findsOneWidget);

    await tester.tap(find.text('Cancel Download'));
    await tester.pumpAndSettle();

    expect(notifier.cancelled, [KokoroModelVariant.fp32]);
    expect(find.byType(TtsModelDownloadDialog), findsNothing);
  });

  testWidgets('下载失败时设置提示不与失败说明重复', (tester) async {
    final notifier = _TestKokoroNotifier(
      const KokoroModelsState({
        KokoroModelVariant.fp32: KokoroModelState(
          downloadStatus: AsrModelDownloadStatus.failed,
        ),
      }),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialTtsSettingsProvider.overrideWithValue(
            const TtsSettings(engine: TtsEngineKind.kokoro),
          ),
          kokoroModelProvider.overrideWith(() => notifier),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: TtsModelDownloadDialog(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('The download did not finish. Estimated download: ~345.9 MB'),
      findsOneWidget,
    );
    expect(
      find.text('You can also choose another speech model in Settings.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('You can retry, or choose another speech model'),
      findsNothing,
    );
  });
}
