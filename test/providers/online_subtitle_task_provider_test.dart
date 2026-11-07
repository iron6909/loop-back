/// 单块在线字幕任务测试。
///
/// 通过受控语音配置/能力记录、假转写客户端、假转码与真实内存数据库，覆盖准入、
/// 单块范围、正常提交、词时间戳来源、取消、并发导入冲突与配置变化后的过期结果。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:echo_loop/database/app_database.dart' as db;
import 'package:echo_loop/database/daos/audio_item_dao.dart';
import 'package:echo_loop/database/providers.dart';
import 'package:echo_loop/features/audio_import/audio_transcode_service.dart';
import 'package:echo_loop/features/onboarding_survey/providers/onboarding_survey_provider.dart';
import 'package:echo_loop/models/audio_item.dart';
import 'package:echo_loop/models/recognition_selection.dart';
import 'package:echo_loop/providers/audio_library_provider.dart';
import 'package:echo_loop/providers/local_transcription_task_provider.dart';
import 'package:echo_loop/providers/online_subtitle_task_provider.dart';
import 'package:echo_loop/providers/speech_capability_provider.dart';
import 'package:echo_loop/providers/speech_configuration_provider.dart';
import 'package:echo_loop/services/speech/speech_capability.dart';
import 'package:echo_loop/services/speech/speech_config.dart';
import 'package:echo_loop/services/speech/speech_config_store.dart';
import 'package:echo_loop/services/speech/speech_transcription_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/mock_providers.dart';

const _modelId = 'openai/whisper-large-v3';
const _credentialVersion = 'credential-a';
final _config = SpeechConfig(
  kind: SpeechProviderKind.openrouter,
  baseUrl: 'https://openrouter.ai/api/v1',
  onlineModels: const {RecognitionPurpose.subtitle: _modelId},
);

/// 只放内存的语音配置替身。
class _MemoryConfigStore extends SpeechConfigStore {
  _MemoryConfigStore({this.config, this.apiKey = 'sk-test'});

  SpeechConfig? config;
  String? apiKey;
  String credentialVersion = _credentialVersion;

  @override
  Future<SpeechConfig?> read() async => config;

  @override
  Future<String?> readApiKey() async => apiKey;

  @override
  Future<String?> readCredentialVersion() async => credentialVersion;
}

/// 只放内存的能力记录替身；[segments] 决定是否具备字幕能力。
class _MemoryCapabilityStore extends SpeechCapabilityStore {
  _MemoryCapabilityStore({this.segments = true, this.wordTimestamps = false});

  bool segments;
  bool wordTimestamps;

  String get identity => SpeechCapability.identityFor(
    kind: _config.kind,
    baseUrl: _config.baseUrl,
    modelId: _modelId,
    credentialVersion: _credentialVersion,
  );

  @override
  Future<SpeechCapability?> read(String identity) async => identity == this.identity
      ? SpeechCapability(
          identity: identity,
          text: true,
          segments: segments,
          wordTimestamps: wordTimestamps,
          validatedAt: DateTime(2026, 11, 7),
        )
      : null;
}

/// 受控转写客户端：记录请求参数，按测试给出结果或阻塞。
class _FakeClient extends SpeechTranscriptionClient {
  _FakeClient({this.result, this.gate});

  SpeechTranscriptionResult? result;
  Completer<void>? gate;
  final List<({String modelId, bool wordTimestamps, Duration duration})> calls =
      [];

  @override
  Future<SpeechTranscriptionResult> transcribe({
    required SpeechConfig config,
    required String apiKey,
    required String modelId,
    required Uint8List audio,
    required String fileName,
    required Duration audioDuration,
    SpeechResponseFormat format = SpeechResponseFormat.verboseJson,
    bool requestWordTimestamps = false,
    String fileContentType = 'audio/wav',
    CancelToken? cancelToken,
  }) async {
    calls.add((
      modelId: modelId,
      wordTimestamps: requestWordTimestamps,
      duration: audioDuration,
    ));
    if (gate != null) await gate!.future;
    return result ??
        const SpeechTranscriptionResult(
          text: 'Hello world.',
          segments: [
            SpeechTranscriptSegment(start: 0.2, end: 1.5, text: 'Hello world.'),
          ],
          segmentsValid: true,
        );
  }
}

/// 假转码：写入指定字节量的占位 WAV（16 kHz 单声道按 32000 字节/秒换算）。
class _FakeTranscode extends AudioTranscodeService {
  _FakeTranscode({this.bytes = 32000});

  int bytes;

  @override
  Future<bool> transcodeToPcmWav16k({
    required File source,
    required File output,
  }) async {
    await output.parent.create(recursive: true);
    await output.writeAsBytes(Uint8List(bytes));
    return true;
  }
}

class _FakeFileOps extends TranscriptionFileOps {
  _FakeFileOps(this.dir);

  final Directory dir;

  @override
  Future<Directory> getDataDir() async => dir;
}

AudioItem _audioItem() => AudioItem(
  id: 'a1',
  name: 'Test',
  audioPath: 'audios/x.m4a',
  addedDate: DateTime(2026),
  totalDuration: 60,
);

Future<void> _seedRow(db.AppDatabase database, AudioItem item) async {
  await database.into(database.audioItems).insert(
    db.AudioItemsCompanion.insert(
      id: item.id,
      name: item.name,
      audioPath: Value(item.audioPath),
      addedDate: item.addedDate,
      updatedAt: DateTime(2026),
    ),
  );
}

void main() {
  late db.AppDatabase database;
  late Directory dataDir;
  late _MemoryConfigStore configStore;
  late _MemoryCapabilityStore capabilityStore;
  late _FakeClient client;
  late _FakeTranscode transcode;

  setUp(() async {
    database = db.AppDatabase(NativeDatabase.memory());
    dataDir = await Directory.systemTemp.createTemp('online_tx_');
    SharedPreferences.setMockInitialValues({});
    configStore = _MemoryConfigStore(config: _config);
    capabilityStore = _MemoryCapabilityStore();
    client = _FakeClient();
    transcode = _FakeTranscode();
  });

  tearDown(() async {
    await database.close();
    if (await dataDir.exists()) await dataDir.delete(recursive: true);
  });

  ProviderContainer buildContainer({AudioItem? item}) {
    final audioItem = item ?? _audioItem();
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        speechConfigStoreProvider.overrideWithValue(configStore),
        speechCapabilityStoreProvider.overrideWithValue(capabilityStore),
        speechTranscriptionClientProvider.overrideWithValue(client),
        transcriptionFileOpsProvider.overrideWithValue(_FakeFileOps(dataDir)),
        localTranscriptionTranscodeServiceProvider.overrideWithValue(transcode),
        audioItemDaoProvider.overrideWithValue(database.audioItemDao),
        audioLibraryProvider.overrideWith(TestAudioLibrary.new),
      ],
    );
    (container.read(audioLibraryProvider.notifier) as TestAudioLibrary)
        .setItems([audioItem]);
    return container;
  }

  test('能力验证通过时一次请求即提交在线字幕与估算词时间戳', () async {
    final item = _audioItem();
    await _seedRow(database, item);
    final container = buildContainer();
    addTearDown(container.dispose);

    await container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .startOnlineTranscription(item, autoMergeShortSentences: false);

    expect(client.calls, hasLength(1));
    expect(client.calls.single.modelId, _modelId);
    expect(client.calls.single.wordTimestamps, isFalse, reason: '未验证词能力时不请求词参数');
    final state = container.read(onlineSubtitleTaskManagerProvider)[item.id];
    expect(state, isA<OnlineSubtitleCompleted>());
    expect((state as OnlineSubtitleCompleted).reportedCost, isNull);
    expect(state.wordTimingSource, TranscriptWordTimingSource.estimated);

    final row = await database.audioItemDao.getById(item.id);
    expect(row?.transcriptSource, TranscriptSource.online.index);
    expect(row?.transcriptWordTimingSource, TranscriptWordTimingSource.estimated.index);
    expect(row?.transcriptSrt, contains('Hello world.'));
    expect(row?.transcriptLanguage, 'en');
  });

  test('模型词时间戳全部对上文本时整份标记为模型提供', () async {
    capabilityStore.wordTimestamps = true;
    client.result = const SpeechTranscriptionResult(
      text: 'Hello world.',
      segments: [
        SpeechTranscriptSegment(start: 0, end: 2, text: 'Hello world.'),
      ],
      words: [
        SpeechTranscriptWord(word: 'Hello', start: 0.1, end: 0.8),
        SpeechTranscriptWord(word: 'world.', start: 0.9, end: 1.9),
      ],
      segmentsValid: true,
      wordsValid: true,
    );
    final item = _audioItem();
    await _seedRow(database, item);
    final container = buildContainer();
    addTearDown(container.dispose);

    await container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .startOnlineTranscription(item, autoMergeShortSentences: false);

    expect(client.calls.single.wordTimestamps, isTrue);
    final row = await database.audioItemDao.getById(item.id);
    expect(row?.transcriptWordTimingSource, TranscriptWordTimingSource.model.index);
    expect(await database.audioItemDao.getWordTimestamps(item.id), contains('Hello'));
  });

  test('配置未通过字幕能力验证时拒绝发送请求', () async {
    capabilityStore.segments = false;
    final item = _audioItem();
    await _seedRow(database, item);
    final container = buildContainer();
    addTearDown(container.dispose);

    await container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .startOnlineTranscription(item);

    expect(client.calls, isEmpty);
    final state = container.read(onlineSubtitleTaskManagerProvider)[item.id];
    expect(
      (state as OnlineSubtitleFailed).reason,
      OnlineSubtitleFailureReason.notVerified,
    );
    expect((await database.audioItemDao.getById(item.id))?.transcriptSrt, isNull);
  });

  test('超出单块范围直接失败，不截断也不发送请求', () async {
    // 2 分 5 秒的 16 kHz WAV。
    transcode.bytes = 32000 * 125;
    final item = _audioItem();
    await _seedRow(database, item);
    final container = buildContainer();
    addTearDown(container.dispose);

    await container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .startOnlineTranscription(item);

    expect(client.calls, isEmpty);
    expect(
      (container.read(onlineSubtitleTaskManagerProvider)[item.id]
              as OnlineSubtitleFailed)
          .reason,
      OnlineSubtitleFailureReason.audioTooLong,
    );
  });

  test('返回片段无效时视为失败，不写字幕', () async {
    client.result = const SpeechTranscriptionResult(
      text: 'Hello world.',
      segmentsValid: false,
    );
    final item = _audioItem();
    await _seedRow(database, item);
    final container = buildContainer();
    addTearDown(container.dispose);

    await container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .startOnlineTranscription(item);

    expect(
      (container.read(onlineSubtitleTaskManagerProvider)[item.id]
              as OnlineSubtitleFailed)
          .reason,
      OnlineSubtitleFailureReason.invalidResult,
    );
    expect((await database.audioItemDao.getById(item.id))?.transcriptSrt, isNull);
  });

  test('取消后不写入字幕，也不保留完成状态', () async {
    final gate = Completer<void>();
    client.gate = gate;
    final item = _audioItem();
    await _seedRow(database, item);
    final container = buildContainer();
    addTearDown(container.dispose);

    final pending = container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .startOnlineTranscription(item);
    await Future<void>.delayed(Duration.zero);
    container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .cancelTranscription(item.id);
    gate.complete();
    await pending;

    expect((await database.audioItemDao.getById(item.id))?.transcriptSrt, isNull);
    expect(
      container.read(onlineSubtitleTaskManagerProvider)[item.id],
      isA<OnlineSubtitleIdle>(),
    );
  });

  test('识别期间用户导入字幕时保留用户内容并报告冲突', () async {
    final gate = Completer<void>();
    client.gate = gate;
    final item = _audioItem();
    await _seedRow(database, item);
    final container = buildContainer();
    addTearDown(container.dispose);

    final pending = container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .startOnlineTranscription(item);
    await Future<void>.delayed(Duration.zero);
    await database.audioItemDao.saveTranscriptContent(
      item.id,
      srt: '1\n00:00:00,000 --> 00:00:01,000\nUser import\n',
      wordTimestampsJson: null,
    );
    gate.complete();
    await pending;

    expect(
      container.read(onlineSubtitleTaskManagerProvider)[item.id],
      isA<OnlineSubtitleConflict>(),
    );
    final row = await database.audioItemDao.getById(item.id);
    expect(row?.transcriptSrt, contains('User import'));
    expect(row?.transcriptSource, isNull);
  });

  test('请求期间凭据版本变化时丢弃结果且不写库', () async {
    final gate = Completer<void>();
    client.gate = gate;
    final item = _audioItem();
    await _seedRow(database, item);
    final container = buildContainer();
    addTearDown(container.dispose);

    final pending = container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .startOnlineTranscription(item);
    await Future<void>.delayed(Duration.zero);
    configStore.credentialVersion = 'credential-b';
    gate.complete();
    await pending;

    expect(
      (container.read(onlineSubtitleTaskManagerProvider)[item.id]
              as OnlineSubtitleFailed)
          .reason,
      OnlineSubtitleFailureReason.configChanged,
    );
    expect((await database.audioItemDao.getById(item.id))?.transcriptSrt, isNull);
  });
}
