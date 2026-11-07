/// 管理字幕弹窗：本机转录是唯一转录入口，历史 auto 字幕只读。
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:echo_loop/database/providers.dart';
import 'package:echo_loop/features/onboarding_survey/providers/onboarding_survey_provider.dart';
import 'package:echo_loop/features/podcast/podcast_transcript_downloader.dart';
import 'package:echo_loop/models/audio_item.dart';
import 'package:echo_loop/models/recognition_selection.dart';
import 'package:echo_loop/providers/audio_library_provider.dart';
import 'package:echo_loop/providers/local_transcription_task_provider.dart';
import 'package:echo_loop/providers/offline_asr_settings_provider.dart';
import 'package:echo_loop/providers/recognition_settings_provider.dart';
import 'package:echo_loop/providers/settings_provider.dart';
import 'package:echo_loop/services/app_logger.dart';
import 'package:echo_loop/services/asr/asr_model_manager.dart';
import 'package:echo_loop/utils/transcript_picker.dart';
import 'package:echo_loop/widgets/manage_subtitles_sheet.dart';
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

/// 模型已下载的 ASR 设置，让转录门控直接放行。
Override _asrReady() {
  const model = AsrModelInfo(
    id: 'test-model',
    displayName: 'Test Model',
    type: AsrModelType.moonshine,
  );
  return offlineAsrSettingsProvider.overrideWith(() => _ReadyAsr(model));
}

class _ReadyAsr extends FakeOfflineAsrSettings {
  _ReadyAsr(AsrModelInfo model)
    : super(
        OfflineAsrSettingsState(
          backend: AsrBackend.offline,
          engineReady: true,
          recommendedModel: model,
          modelStates: const {
            'test-model': AsrModelState(
              downloadStatus: AsrModelDownloadStatus.downloaded,
            ),
          },
        ),
      );

  @override
  Future<void> refreshInstalledStates({bool Function()? shouldCommit}) async {}
}

/// 固定三用途选择，验证字幕入口读的是与设置页同一份状态。
class _FixedRecognitionSettings extends RecognitionSettingsNotifier {
  _FixedRecognitionSettings(this._fixed);

  final RecognitionSettings _fixed;

  @override
  RecognitionSettings build() => _fixed;
}

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
        _asrReady(),
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

  testWidgets('默认进入本机转录，且不提供自动语言检测', (tester) async {
    manager = _RecordingManager();
    await tester.pumpWidget(
      buildSheet(createTestAudioItem(transcriptPath: null)),
    );
    await tester.pumpAndSettle();
    await open(tester);

    expect(find.text('On-Device Transcription'), findsOneWidget);
    expect(find.text('Cloud Transcription'), findsNothing);
    expect(find.text('Auto Detect'), findsNothing);
    expect(find.text('English'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Start Transcription'),
      findsOneWidget,
    );
  });

  testWidgets('提交时发现字幕已被用户替换：提示冲突并保留转录入口', (tester) async {
    manager = _RecordingManager();
    final item = createTestAudioItem(transcriptPath: null);
    await tester.pumpWidget(buildSheet(item));
    await tester.pumpAndSettle();
    await open(tester);

    manager.emit(item.id, const LocalTranscriptionConflict());
    await tester.pumpAndSettle();

    expect(
      find.textContaining('replaced by another action'),
      findsOneWidget,
    );
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

  testWidgets('字幕入口与设置页共用同一份用途选择', (tester) async {
    manager = _RecordingManager();
    await tester.pumpWidget(
      buildSheet(
        createTestAudioItem(transcriptPath: null),
        extra: [
          recognitionSettingsProvider.overrideWith(
            () => _FixedRecognitionSettings(
              const RecognitionSettings(
                subtitle: RecognitionSelection.local('whisper-small-en-int8'),
                shadowing: RecognitionSelection.local('whisper-tiny-en-int8'),
                retell: RecognitionSelection.local('whisper-base-en-int8'),
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await open(tester);

    // 字幕入口直接展示共享状态里的字幕档位，不维护弹窗镜像。
    expect(find.text('Whisper Small (English)'), findsOneWidget);
  });

  testWidgets('已有字幕时取消覆盖确认则不启动转录', (tester) async {    manager = _RecordingManager();
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
    expect(find.text('On-Device Transcription'), findsOneWidget);
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
