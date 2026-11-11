import 'package:dio/dio.dart';
import 'package:loop_back/providers/shared_preferences_provider.dart';
import 'package:loop_back/l10n/app_localizations.dart';
import 'package:loop_back/models/dictionary/dictionary_lookup_result.dart';
import 'package:loop_back/providers/dictionary/dictionary_offline_resources_provider.dart';
import 'package:loop_back/providers/dictionary/dictionary_registry.dart';
import 'package:loop_back/providers/dictionary/dictionary_settings_provider.dart';
import 'package:loop_back/providers/dictionary_provider.dart';
import 'package:loop_back/providers/offline_asr_settings_provider.dart';
import 'package:loop_back/providers/pronunciation/pronunciation_providers.dart';
import 'package:loop_back/screens/dictionary_settings_screen.dart';
import 'package:loop_back/services/asr/asr_model_catalog.dart';
import 'package:loop_back/services/dictionary/dictionary_source.dart';
import 'package:loop_back/services/download/download_failure.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/mock_providers.dart';

class _FakeSource implements DictionarySource {
  @override
  final String id;
  @override
  final bool canBeDisabled;
  _FakeSource(this.id, {required this.canBeDisabled});
  @override
  IconData get icon => Icons.abc;
  @override
  bool get requiresNetwork => false;
  @override
  Future<DictionaryLookupResult?> lookup(
    DictionaryLookupRequest request, {
    CancelToken? cancelToken,
  }) async => null;
}

/// 测试用词典 Notifier：build 返回注入的固定状态，副作用置空。
class _FakeDictionary extends Dictionary {
  final DictionaryState _initial;
  _FakeDictionary(this._initial);

  @override
  DictionaryState build() => _initial;

  @override
  Future<void> retryDownload() async {}
}

/// 测试用发音库 Notifier：build 返回注入的固定状态，副作用置空。
class _FakePronunciationLibrary extends PronunciationLibraryNotifier {
  final PronunciationLibraryState _initial;
  _FakePronunciationLibrary(this._initial);

  @override
  PronunciationLibraryState build() => _initial;

  @override
  Future<void> ensureDownloaded() async {}

  @override
  Future<void> retryDownload() async {}
}

/// 测试用逐语言词典资源 Notifier：build 返回固定状态，下载副作用记录调用。
class _FakeDictionaryResource extends DictionaryResourceNotifier {
  _FakeDictionaryResource(this.installedLanguage);

  final String installedLanguage;
  final downloadedLanguages = <String>[];
  final retriedLanguages = <String>[];

  @override
  DictionaryResourceState build(String arg) => DictionaryResourceState(
    status: arg == installedLanguage
        ? DictionaryStatus.downloaded
        : DictionaryStatus.notDownloaded,
  );

  @override
  Future<void> download() async {
    downloadedLanguages.add(arg);
  }

  @override
  Future<void> retryDownload() async {
    retriedLanguages.add(arg);
  }
}

/// 测试用：逐语言词典仍处于本地安装检查中（显式 loading 态）。
class _FakeCheckingDictionaryResource extends DictionaryResourceNotifier {
  @override
  DictionaryResourceState build(String arg) =>
      const DictionaryResourceState();

  @override
  Future<void> download() async {}

  @override
  Future<void> retryDownload() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  final fakeSources = <DictionarySource>[
    _FakeSource('local', canBeDisabled: false),
    _FakeSource('ai', canBeDisabled: false),
    _FakeSource('cambridge', canBeDisabled: true),
  ];

  (ProviderContainer, Widget) build({
    DictionaryStatus dictStatus = DictionaryStatus.downloaded,
    DownloadFailureKind? dictFailure,
    String nativeLanguage = 'zh-CN',
    PronunciationLibraryStatus pronunciationStatus =
        PronunciationLibraryStatus.ready,
    DownloadFailureKind? pronunciationFailure,
    DictionaryResourceNotifier? resourceNotifier,
  }) {
    final container = ProviderContainer(
      overrides: [
        dictionarySourcesProvider.overrideWithValue(fakeSources),
        sharedPreferencesProvider.overrideWithValue(prefs),
        dictionaryProvider.overrideWith(
          () => _FakeDictionary(
            DictionaryState(
              status: dictStatus,
              failure: dictFailure,
              nativeLanguage: nativeLanguage,
            ),
          ),
        ),
        pronunciationLibraryProvider.overrideWith(
          () => _FakePronunciationLibrary(
            PronunciationLibraryState(
              status: pronunciationStatus,
              failure: pronunciationFailure,
            ),
          ),
        ),
        dictionaryResourceProvider.overrideWith(
          () => resourceNotifier ?? _FakeDictionaryResource(nativeLanguage),
        ),
        offlineAsrOverride(),
      ],
    );
    addTearDown(container.dispose);
    return (
      container,
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: [Locale('en'), Locale('zh')],
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: DictionarySettingsScreen(),
        ),
      ),
    );
  }

  testWidgets('本地/AI 锁定，Cambridge 可开关', (tester) async {
    final (_, widget) = build();
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();

    // local + ai 显示「Always on」锁定
    expect(find.text('Always on'), findsNWidgets(2));
    // 自动发音、网页广告过滤、Cambridge 三个 Switch
    expect(find.byType(Switch), findsNWidgets(3));
  });

  testWidgets('网页词典广告过滤默认关闭并可开启', (tester) async {
    final (container, widget) = build();
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();

    expect(find.text('Block ads in web dictionaries'), findsOneWidget);
    final toggle = find.byType(Switch).at(1);
    expect(tester.widget<Switch>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      container.read(dictionarySettingsNotifierProvider).adFilteringEnabled,
      isTrue,
    );
  });

  testWidgets('顶部自动发音开关默认开启并可切换', (tester) async {
    final (container, widget) = build();
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();

    expect(find.text('Auto-play Pronunciation'), findsOneWidget);
    final toggle = find.byType(Switch).first;
    expect(tester.widget<Switch>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      container.read(dictionarySettingsNotifierProvider).autoSpeakOnLookup,
      isFalse,
    );
  });

  testWidgets('切换默认词典', (tester) async {
    final (container, widget) = build();
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();

    expect(
      container.read(dictionarySettingsNotifierProvider).defaultSourceId,
      'local',
    );
    // 默认区在前，首个 'AI Dictionary' 即默认区项
    await tester.tap(find.text('AI Dictionary').first);
    await tester.pumpAndSettle();
    expect(
      container.read(dictionarySettingsNotifierProvider).defaultSourceId,
      'ai',
    );
  });

  testWidgets('禁用 Cambridge → 移出默认区选项', (tester) async {
    final (container, widget) = build();
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();

    // 初始：默认区 + 词典源区各一个 Cambridge
    expect(find.text('Cambridge'), findsNWidgets(2));

    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();

    expect(container.read(dictionarySettingsNotifierProvider).disabledIds, {
      'cambridge',
    });
    // 默认区不再列出 Cambridge，仅词典源区保留
    expect(find.text('Cambridge'), findsOneWidget);
  });

  testWidgets('离线资源区展示 zh-CN/zh-TW 来源许可与发音库来源', (tester) async {
    final (_, widget) = build();
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();

    expect(find.text('Offline Resources'), findsOneWidget);
    expect(find.text('简体中文'), findsOneWidget);
    expect(find.text('繁體中文'), findsOneWidget);
    expect(
      find.text('Data: ECDICT (MIT) · Hosted on: banko3/loop-back'),
      findsNWidgets(2),
    );
    expect(find.text('Offline Word Pronunciation'), findsOneWidget);
    expect(find.text('Hosted on: banko3/loop-back'), findsOneWidget);
  });

  testWidgets('非当前母语词典未下载时提供下载入口并触发按需下载', (tester) async {
    final resourceNotifier = _FakeDictionaryResource('zh-CN');
    final (_, widget) = build(resourceNotifier: resourceNotifier);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();

    // 当前 zh-CN 已下载，非当前 zh-TW 未下载并给出下载入口。
    expect(find.text('Dictionary not yet downloaded'), findsOneWidget);
    final download = find.text('Download');
    expect(download, findsOneWidget);

    await tester.ensureVisible(download);
    await tester.pumpAndSettle();
    await tester.tap(download);
    await tester.pumpAndSettle();

    expect(resourceNotifier.downloadedLanguages, ['zh-TW']);
  });

  testWidgets('非当前母语安装检查未完成时显示加载态而非未下载', (tester) async {
    final (_, widget) = build(
      resourceNotifier: _FakeCheckingDictionaryResource(),
    );
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();

    expect(find.text('Loading'), findsOneWidget);
    expect(find.text('Dictionary not yet downloaded'), findsNothing);
  });

  testWidgets('当前母语词典失败展示可读原因并可重试', (tester) async {
    final (_, widget) = build(
      dictStatus: DictionaryStatus.failed,
      dictFailure: DownloadFailureKind.network,
    );
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();

    expect(
      find.text('Network error. Check your connection and retry.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('发音库失败展示原因并可重试', (tester) async {
    final (_, widget) = build(
      pronunciationStatus: PronunciationLibraryStatus.failed,
      pronunciationFailure: DownloadFailureKind.verification,
    );
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();

    expect(
      find.text('Downloaded file verification failed. Please retry.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('下载来源切换与语音识别设置同源', (tester) async {
    final (container, widget) = build();
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();

    expect(
      container.read(offlineAsrSettingsProvider).downloadSource,
      AsrDownloadSource.huggingFace,
    );

    await tester.ensureVisible(find.text('Model Source'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Model Source'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('hf-mirror.com (mirror)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('hf-mirror.com (mirror)'));
    await tester.pumpAndSettle();

    expect(
      container.read(offlineAsrSettingsProvider).downloadSource,
      AsrDownloadSource.huggingFaceMirror,
    );
  });
}
