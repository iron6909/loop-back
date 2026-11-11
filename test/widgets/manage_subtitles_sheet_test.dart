/// 管理字幕弹窗：本机转录是唯一转录入口，历史 auto 字幕只读。
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:loop_back/database/providers.dart';
import 'package:loop_back/providers/shared_preferences_provider.dart';
import 'package:loop_back/features/podcast/podcast_transcript_downloader.dart';
import 'package:loop_back/models/audio_item.dart';
import 'package:loop_back/models/recognition_selection.dart';
import 'package:loop_back/providers/audio_library_provider.dart';
import 'package:loop_back/providers/local_transcription_model_provider.dart';
import 'package:loop_back/providers/local_transcription_task_provider.dart';
import 'package:loop_back/providers/offline_asr_settings_provider.dart';
import 'package:loop_back/providers/online_subtitle_task_provider.dart';
import 'package:loop_back/providers/recognition_settings_provider.dart';
import 'package:loop_back/providers/speech_capability_provider.dart';
import 'package:loop_back/services/speech/practice_online_transcriber.dart';
import 'package:loop_back/services/speech/speech_config.dart';
import 'package:loop_back/services/speech/speech_config_store.dart';
import 'package:loop_back/providers/speech_configuration_provider.dart';
import 'package:loop_back/providers/settings_provider.dart';
import 'package:loop_back/services/app_logger.dart';
import 'package:loop_back/services/asr/asr_model_manager.dart';
import 'package:loop_back/utils/transcript_picker.dart';
import 'package:loop_back/widgets/manage_subtitles_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/mock_providers.dart';
import '../helpers/test_app.dart';

/// 记录启动参数的本机转录管理器；真实流水线由 provider 单测覆盖。
class _RecordingManager extends TestLocalTranscriptionTaskManager {
  _RecordingManager([super.initialState]);
  final calls = <(String, bool)>[];
  final cancels = <String>[];
  void emit(String id, LocalTranscriptionState task) =>
      state = {...state, id: task};

  @override
  Future<void> startLocalTranscription(
    AudioItem audioItem, {
    required AsrModelInfo model,
    bool autoMergeShortSentences = true,
  }) async {
    calls.add((model.id, autoMergeShortSentences));
  }

  @override
  void cancelTranscription(String audioId) {
    cancels.add(audioId);
    super.cancelTranscription(audioId);
  }
}

const _podcastSrt = '1\n00:00:00,000 --> 00:00:01,000\nHello podcast\n';

class _FakeDownloader extends PodcastTranscriptDownloader {
  _FakeDownloader({this.text = _podcastSrt, this.error});
  final String text;
  final Object? error;
  final urls = <String>[];

  @override
  Future<String> download(
    String url, {
    required String format,
    CancelToken? cancelToken,
  }) async {
    urls.add(url);
    if (error case final failure?) throw failure;
    return text;
  }
}

/// 默认模型：与评分侧推荐的档位无关，验证字幕读自己的档位。
const _testModel = AsrModelInfo(
  id: 'test-model',
  displayName: 'Test Model',
  type: AsrModelType.moonshine,
);

/// 固定安装状态的 ASR 设置，让转录门控按测试指定的状态放行或弹下载。
Override _asrReady({
  AsrModelInfo model = _testModel,
  AsrModelDownloadStatus status = AsrModelDownloadStatus.downloaded,
}) => offlineAsrSettingsProvider.overrideWith(
  () => _ReadyAsr(model, status: status),
);

class _ReadyAsr extends FakeOfflineAsrSettings {
  _ReadyAsr(
    AsrModelInfo model, {
    AsrModelDownloadStatus status = AsrModelDownloadStatus.downloaded,
  }) : super(
         OfflineAsrSettingsState(
           backend: AsrBackend.offline,
           engineReady: true,
           recommendedModel: model,
           modelStates: {model.id: AsrModelState(downloadStatus: status)},
         ),
       );

  @override
  Future<void> refreshInstalledStates({bool Function()? shouldCommit}) async {}
}

/// 只放内存的语音配置替身，避免 widget 测试访问安全存储。
class _SpeechStore extends SpeechConfigStore {
  _SpeechStore(this.config);

  final SpeechConfig? config;

  @override
  Future<SpeechConfig?> read() async => config;

  @override
  Future<String?> readApiKey() async => 'sk-test';

  @override
  Future<String?> readCredentialVersion() async => 'credential-a';
}

/// 字幕在线准入替身：可用性、阻断原因与在线模型摘要来自同一份测试配置。
List<Override> _subtitleOnline({
  required bool available,
  PracticeOnlineAccessDenial blocked =
      PracticeOnlineAccessDenial.capabilityNotSuitable,
  String modelId = 'openai/whisper-large-v3',
}) => [
  onlineSubtitleAvailableProvider.overrideWithValue(available),
  onlineModeBlockReasonProvider(
    RecognitionPurpose.subtitle,
  ).overrideWith((ref) => available ? null : blocked),
  speechConfigStoreProvider.overrideWithValue(
    _SpeechStore(
      SpeechConfig(
        kind: SpeechProviderKind.openrouter,
        baseUrl: 'https://openrouter.ai/api/v1',
        onlineModels: {RecognitionPurpose.subtitle: modelId},
      ),
    ),
  ),
];

void main() {
  late _RecordingManager manager;
  late SharedPreferences prefs;

  setUp(() async {
    AppLogger.instance.clear();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Widget buildSheet(
    AudioItem item, {
    Future<TranscriptDecodeResult?> Function()? picker,
    Override? asrOverride,
    List<Override> extra = const [],
  }) {
    return createTestApp(
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => ManageSubtitlesSheet(
              audioItem: item,
              transcriptContentPicker: picker,
            ),
          ),
          child: const Text('Open'),
        ),
      ),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        audioLibraryProvider.overrideWith(
          () => TestAudioLibrary(AudioLibraryState(audioItems: [item])),
        ),
        localTranscriptionTaskManagerProvider.overrideWith(() => manager),
        audioItemDaoProvider.overrideWithValue(TestAudioItemDao()),
        asrOverride ?? _asrReady(),
        ...extra,
      ],
    );
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> pressPrimary(WidgetTester tester) async {
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
  }

  testWidgets('默认显示模型转录与本机摘要，并提示去语音识别设置修改', (tester) async {
    manager = _RecordingManager();
    await tester.pumpWidget(
      buildSheet(createTestAudioItem(transcriptPath: null)),
    );
    await tester.pumpAndSettle();
    await open(tester);

    expect(find.text('Model transcription'), findsOneWidget);
    expect(find.text('On-device · test-model'), findsOneWidget);
    expect(
      find.text(
        'Change the subtitle mode and model in Settings → Speech recognition '
        '→ Recognition modes',
      ),
      findsOneWidget,
    );
    expect(find.text('Auto Detect'), findsNothing);
    expect(
      find.widgetWithText(FilledButton, 'Start Transcription'),
      findsOneWidget,
    );
    // 不再并列本地 / 在线两个转录入口，也不在弹窗内选模型与语言。
    expect(find.text('On-Device Transcription'), findsNothing);
    expect(find.text('Online transcription'), findsNothing);
    expect(find.text('Local Upload'), findsOneWidget);
    expect(find.text('Select Language'), findsNothing);
    expect(find.text('Whisper Small (English)'), findsNothing);
  });

  testWidgets('提交时发现字幕已被用户替换：提示冲突并保留转录入口', (tester) async {
    manager = _RecordingManager();
    final item = createTestAudioItem(transcriptPath: null);
    await tester.pumpWidget(buildSheet(item));
    await tester.pumpAndSettle();
    await open(tester);

    manager.emit(item.id, const LocalTranscriptionConflict());
    await tester.pumpAndSettle();

    expect(find.textContaining('replaced by another action'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('历史 auto 字幕只读：提示且按钮禁用，不发起转录', (tester) async {
    manager = _RecordingManager();
    final item = createTestAudioItem().copyWith(transcriptLanguage: 'auto');
    await tester.pumpWidget(buildSheet(item));
    await tester.pumpAndSettle();
    await open(tester);

    expect(
      find.textContaining('Existing auto-detected subtitles'),
      findsOneWidget,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(manager.calls, isEmpty);
  });

  testWidgets('模型就绪时启动本机转录，并沿用短句合并偏好', (tester) async {
    manager = _RecordingManager();
    await tester.pumpWidget(
      buildSheet(
        createTestAudioItem(transcriptPath: null),
        extra: [
          appSettingsProvider.overrideWith(
            () => TestAppSettings(
              const AppSettingsState(aiTranscriptionAutoMergeEnabled: false),
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await open(tester);
    await pressPrimary(tester);

    expect(manager.calls, [('test-model', false)]);
  });

  testWidgets('本机方式使用字幕自己的档位，摘要显示该档位名称', (tester) async {
    manager = _RecordingManager();
    final small = availableModels.firstWhere(
      (model) => model.id == 'whisper-small-en-int8',
    );
    await prefs.setString(localTranscriptionModelKey, small.id);
    await tester.pumpWidget(
      buildSheet(
        createTestAudioItem(transcriptPath: null),
        asrOverride: _asrReady(model: small),
      ),
    );
    await tester.pumpAndSettle();
    await open(tester);

    expect(find.text('On-device · Whisper Small (English)'), findsOneWidget);
    await pressPrimary(tester);

    expect(manager.calls, [('whisper-small-en-int8', true)]);
  });

  testWidgets('字幕选择本机但模型未下载时走下载门控，不改走在线', (tester) async {
    manager = _RecordingManager();
    final online = TestOnlineSubtitleTaskManager();
    await tester.pumpWidget(
      buildSheet(
        createTestAudioItem(transcriptPath: null),
        asrOverride: _asrReady(status: AsrModelDownloadStatus.notDownloaded),
        extra: [onlineSubtitleTaskManagerProvider.overrideWith(() => online)],
      ),
    );
    await tester.pumpAndSettle();
    await open(tester);
    await pressPrimary(tester);

    expect(find.text('Speech Recognition Model Required'), findsOneWidget);
    expect(manager.calls, isEmpty);
    expect(online.calls, isEmpty, reason: '本机未就绪不会静默改走在线');
  });

  testWidgets('只保留模型转录与本地上传，不提供本地 / 在线切换', (tester) async {
    manager = _RecordingManager();
    await tester.pumpWidget(
      buildSheet(createTestAudioItem(transcriptPath: null)),
    );
    await tester.pumpAndSettle();
    await open(tester);

    expect(find.text('Model transcription'), findsOneWidget);
    expect(find.text('Local Upload'), findsOneWidget);
    expect(find.text('On-Device Transcription'), findsNothing);
    expect(find.text('Online transcription'), findsNothing);
    expect(find.text('Whisper Small (English)'), findsNothing);
    expect(find.text('Select Language'), findsNothing);
  });

  testWidgets('已有字幕时取消覆盖确认则不启动转录', (tester) async {
    manager = _RecordingManager();
    await tester.pumpWidget(buildSheet(createTestAudioItem()));
    await tester.pumpAndSettle();
    await open(tester);
    await pressPrimary(tester);

    expect(find.text('Overwrite existing subtitles?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(manager.calls, isEmpty);
    expect(find.byType(ManageSubtitlesSheet), findsOneWidget);
  });

  testWidgets('转录进行中显示进度与保持前台提示，取消回到选项', (tester) async {
    manager = _RecordingManager({
      'test-audio-1': const LocalTranscriptionTranscribing(progress: 0.3),
    });
    await tester.pumpWidget(buildSheet(createTestAudioItem()));
    await tester.pumpAndSettle();
    await open(tester);

    expect(find.textContaining('Keep the app open'), findsOneWidget);
    expect(find.text('30% done'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(manager.cancels, ['test-audio-1']);
    expect(find.text('Model transcription'), findsOneWidget);
  });

  testWidgets('转录失败显示错误提示且保留字幕编辑入口', (tester) async {
    manager = _RecordingManager();
    await tester.pumpWidget(buildSheet(createTestAudioItem()));
    await tester.pumpAndSettle();
    await open(tester);
    manager.emit(
      'test-audio-1',
      const LocalTranscriptionFailed(code: 'decode'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Transcription failed'), findsOneWidget);
    expect(find.byTooltip('Edit subtitles'), findsOneWidget);
  });

  testWidgets('本机上传成功写入字幕并关闭弹窗', (tester) async {
    manager = _RecordingManager();
    final dao = TestAudioItemDao();
    await tester.pumpWidget(
      buildSheet(
        createTestAudioItem(transcriptPath: null),
        picker: () async => const TranscriptDecodeResult(
          text: '1\n00:00:00,000 --> 00:00:01,000\nUploaded line\n',
          charset: 'utf-8',
          ext: 'srt',
        ),
        extra: [audioItemDaoProvider.overrideWithValue(dao)],
      ),
    );
    await tester.pumpAndSettle();
    await open(tester);
    await tester.tap(find.text('Local Upload'));
    await tester.pumpAndSettle();
    await pressPrimary(tester);

    expect(dao.transcriptSrtStore['test-audio-1'], contains('Uploaded line'));
    expect(find.byType(ManageSubtitlesSheet), findsNothing);
  });

  testWidgets('本机上传失败保留完整错误与日志，不写入字幕', (tester) async {
    manager = _RecordingManager();
    final dao = TestAudioItemDao();
    const path = '/private/var/mobile/Containers/subtitle.srt';
    await tester.pumpWidget(
      buildSheet(
        createTestAudioItem(transcriptPath: null),
        picker: () async => throw const FileSystemException(
          'Operation not permitted',
          path,
          OSError('Permission denied', 1),
        ),
        extra: [audioItemDaoProvider.overrideWithValue(dao)],
      ),
    );
    await tester.pumpAndSettle();
    await open(tester);
    await tester.tap(find.text('Local Upload'));
    await tester.pumpAndSettle();
    await runZoned<Future<void>>(
      () => pressPrimary(tester),
      zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
    );

    expect(find.textContaining(path), findsOneWidget);
    expect(find.textContaining('Operation not permitted'), findsOneWidget);
    expect(dao.transcriptSrtStore['test-audio-1'], isNull);
    expect(
      AppLogger.instance.entries.map((e) => e.toString()),
      contains(
        allOf(contains('[SubtitleUpload] failed local upload'), contains(path)),
      ),
    );

    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
  });

  group('播客字幕下载', () {
    const podcastUrl = 'https://example.com/episode.srt';

    AudioItem podcastItem({bool hasTranscript = false}) =>
        createTestAudioItem(
          transcriptPath: hasTranscript ? 'transcripts/test.srt' : null,
        ).copyWith(
          podcastTranscriptUrl: podcastUrl,
          podcastTranscriptFormat: 'srt',
        );

    testWidgets('有字幕地址时默认选中并下载入库后关闭', (tester) async {
      manager = _RecordingManager();
      final downloader = _FakeDownloader();
      final dao = TestAudioItemDao();
      await tester.pumpWidget(
        buildSheet(
          podcastItem(),
          extra: [
            podcastTranscriptDownloaderProvider.overrideWithValue(downloader),
            audioItemDaoProvider.overrideWithValue(dao),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await open(tester);

      expect(find.text('Download Podcast Subtitles'), findsOneWidget);
      await pressPrimary(tester);

      expect(downloader.urls, [podcastUrl]);
      expect(dao.transcriptSrtStore['test-audio-1'], contains('Hello podcast'));
      expect(find.byType(ManageSubtitlesSheet), findsNothing);
    });

    testWidgets('已有字幕取消覆盖不下载，确认覆盖后才替换', (tester) async {
      manager = _RecordingManager();
      final downloader = _FakeDownloader();
      final dao = TestAudioItemDao();
      dao.transcriptSrtStore['test-audio-1'] = 'original';
      await tester.pumpWidget(
        buildSheet(
          podcastItem(hasTranscript: true),
          extra: [
            podcastTranscriptDownloaderProvider.overrideWithValue(downloader),
            audioItemDaoProvider.overrideWithValue(dao),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await open(tester);
      await pressPrimary(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(downloader.urls, isEmpty);
      expect(dao.transcriptSrtStore['test-audio-1'], 'original');
      await pressPrimary(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Overwrite'));
      await tester.pumpAndSettle();
      expect(downloader.urls, [podcastUrl]);
      expect(dao.transcriptSrtStore['test-audio-1'], contains('Hello podcast'));
    });

    testWidgets('下载失败显示内联错误且不改动字幕', (tester) async {
      manager = _RecordingManager();
      final dao = TestAudioItemDao();
      await tester.pumpWidget(
        buildSheet(
          podcastItem(),
          extra: [
            podcastTranscriptDownloaderProvider.overrideWithValue(
              _FakeDownloader(
                error: const PodcastTranscriptException('HTTP 500'),
              ),
            ),
            audioItemDaoProvider.overrideWithValue(dao),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await open(tester);
      await pressPrimary(tester);

      expect(find.textContaining('HTTP 500'), findsOneWidget);
      expect(dao.transcriptSrtStore['test-audio-1'], isNull);
      expect(find.byType(ManageSubtitlesSheet), findsOneWidget);

      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
    });

    testWidgets('下载到空字幕时提示为空且不入库', (tester) async {
      manager = _RecordingManager();
      final dao = TestAudioItemDao();
      await tester.pumpWidget(
        buildSheet(
          podcastItem(),
          extra: [
            podcastTranscriptDownloaderProvider.overrideWithValue(
              _FakeDownloader(text: ''),
            ),
            audioItemDaoProvider.overrideWithValue(dao),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await open(tester);
      await pressPrimary(tester);

      expect(find.textContaining('no subtitle entries found'), findsOneWidget);
      expect(dao.transcriptSrtStore['test-audio-1'], isNull);

      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
    });
  });

  testWidgets('字幕选择在线且准入通过时启动在线任务，不要求本机模型就绪', (tester) async {
    manager = _RecordingManager();
    final online = TestOnlineSubtitleTaskManager();
    final item = createTestAudioItem(transcriptPath: null);
    await prefs.setString(subtitleModePrefsKey, RecognitionMode.online.name);
    await tester.pumpWidget(
      buildSheet(
        item,
        extra: [
          onlineSubtitleTaskManagerProvider.overrideWith(() => online),
          ..._subtitleOnline(available: true),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await open(tester);

    // 只有模型转录一个入口，摘要直接显示当前在线方式与模型。
    expect(find.text('Model transcription'), findsOneWidget);
    expect(
      find.text('Online speech · openai/whisper-large-v3'),
      findsOneWidget,
    );
    expect(find.text('On-Device Transcription'), findsNothing);
    expect(find.text('Online transcription'), findsNothing);

    await pressPrimary(tester);

    expect(online.calls, [(item.id, true)]);
    expect(manager.calls, isEmpty, reason: '在线不走本机转录入口');
  });

  testWidgets('字幕选择在线但模型不支持片段时间戳时禁用转录并说明原因', (tester) async {
    manager = _RecordingManager();
    final online = TestOnlineSubtitleTaskManager();
    await prefs.setString(subtitleModePrefsKey, RecognitionMode.online.name);
    await tester.pumpWidget(
      buildSheet(
        createTestAudioItem(transcriptPath: null),
        extra: [
          onlineSubtitleTaskManagerProvider.overrideWith(() => online),
          ..._subtitleOnline(
            available: false,
            blocked: PracticeOnlineAccessDenial.capabilityNotSuitable,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await open(tester);

    // 模型转录与主按钮禁用，并直接说明还缺片段时间戳；本地上传不受影响。
    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, 'Model transcription'),
    );
    expect(tile.enabled, isFalse);
    expect(find.textContaining('no segment timestamps'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Local Upload'))
          .enabled,
      isTrue,
    );

    // 禁用时点击不会静默改走本机，也不会发起在线任务。
    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(manager.calls, isEmpty);
    expect(online.calls, isEmpty);
  });

  testWidgets('字幕在线缺配置时模型转录禁用并说明下一步', (tester) async {
    manager = _RecordingManager();
    await prefs.setString(subtitleModePrefsKey, RecognitionMode.online.name);
    await tester.pumpWidget(
      buildSheet(
        createTestAudioItem(transcriptPath: null),
        extra: [
          ..._subtitleOnline(
            available: false,
            blocked: PracticeOnlineAccessDenial.missingConfiguration,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await open(tester);

    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, 'Model transcription'),
    );
    expect(tile.enabled, isFalse);
    expect(
      find.textContaining('Set the service address under Settings'),
      findsOneWidget,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('在线分块任务进行中显示块进度与取消入口', (tester) async {
    manager = _RecordingManager();
    final online = TestOnlineSubtitleTaskManager({
      'test-audio-1': const OnlineSubtitleWorking(
        service: 'openrouter',
        modelId: 'openai/whisper-large-v3',
        completedChunks: 1,
        totalChunks: 3,
      ),
    });
    final item = createTestAudioItem(transcriptPath: null);
    await tester.pumpWidget(
      buildSheet(
        item,
        extra: [onlineSubtitleTaskManagerProvider.overrideWith(() => online)],
      ),
    );
    await tester.pumpAndSettle();
    await open(tester);

    expect(find.textContaining('Chunks done: 1/3'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('可续试失败在重开弹窗后保留：显示失败块、未知费用与重试入口', (tester) async {
    manager = _RecordingManager();
    final online = TestOnlineSubtitleTaskManager({
      'test-audio-1': const OnlineSubtitleFailed(
        OnlineSubtitleFailureReason.unknown,
        completedChunks: 2,
        totalChunks: 3,
        failedChunk: 3,
        mayHaveBeenCharged: true,
        retryable: true,
      ),
    });
    final item = createTestAudioItem(transcriptPath: null);
    await prefs.setString(subtitleModePrefsKey, RecognitionMode.online.name);
    await tester.pumpWidget(
      buildSheet(
        item,
        extra: [
          onlineSubtitleTaskManagerProvider.overrideWith(() => online),
          ..._subtitleOnline(available: true),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await open(tester);

    // 失败位置与“可能重复计费”都要如实说明，且失败态不随弹窗重开被清掉。
    expect(find.textContaining('Failed at chunk 3/3'), findsOneWidget);
    expect(find.textContaining('may have been charged'), findsOneWidget);
    await pressPrimary(tester);

    expect(online.calls, [(item.id, true)], reason: '重试只继续未完成块');
    expect(manager.calls, isEmpty);
  });

  testWidgets('已保存字幕如实显示整体词时间戳来源', (tester) async {
    manager = _RecordingManager();
    await tester.pumpWidget(
      buildSheet(
        createTestAudioItem(
          transcriptSource: TranscriptSource.online,
          transcriptWordTimingSource: TranscriptWordTimingSource.mixed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await open(tester);

    expect(find.textContaining('Word timing source: mixed'), findsOneWidget);
  });

  testWidgets('删除确认显示收藏与进度警告', (tester) async {
    manager = _RecordingManager();
    await tester.pumpWidget(buildSheet(createTestAudioItem()));
    await tester.pumpAndSettle();
    await open(tester);
    await tester.tap(find.byTooltip('Delete Subtitles'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Deleting the subtitles will also clear all saved sentences and learning progress of this audio.',
      ),
      findsOneWidget,
    );
  });
}
