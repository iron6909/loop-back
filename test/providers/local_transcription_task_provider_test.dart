// LocalTranscriptionTaskManager 单元测试
//
// 通过 fake 引擎 / 转码服务 / fileOps + 内存 DB 验证完整流水线、
// 状态转换、专用引擎生命周期（用后 dispose）、空结果与失败处理。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:loop_back/database/app_database.dart' as db;
import 'package:loop_back/database/daos/audio_item_dao.dart';
import 'package:loop_back/database/providers.dart';
import 'package:loop_back/features/audio_import/audio_transcode_service.dart';
import 'package:loop_back/providers/shared_preferences_provider.dart';
import 'package:loop_back/models/audio_item.dart';
import 'package:loop_back/models/recognition_selection.dart';
import 'package:loop_back/providers/audio_library_provider.dart';
import 'package:loop_back/providers/local_transcription_task_provider.dart';
import 'package:loop_back/providers/recognition_settings_provider.dart';
import 'package:loop_back/services/asr/asr_model_manager.dart';
import 'package:loop_back/providers/asr_engine_provider.dart';
import 'package:loop_back/services/asr/offline_asr_engine.dart';

import '../helpers/mock_providers.dart';

// ─── Fakes ──────────────────────────────────────────────

class MockTranscriptionFileOps extends Mock implements TranscriptionFileOps {}

/// 假引擎：记录调用、返回预设分段并驱动进度回调。
class _FakeEngine implements OfflineAsrEngine {
  _FakeEngine(this.segments, {this.throwOnTranscribe = false});

  final List<AsrSegment> segments;
  final bool throwOnTranscribe;
  int initializeCalls = 0;
  int disposeCalls = 0;

  @override
  String get name => 'fake';
  @override
  bool get isReady => initializeCalls > 0 && disposeCalls == 0;
  @override
  AsrModelInfo? get currentModel => null;

  @override
  Future<void> initialize(AsrModelConfig config) async {
    initializeCalls++;
  }

  @override
  Future<AsrResult> transcribe(String wavPath) async =>
      const AsrResult(text: '', inferenceTime: Duration.zero);

  @override
  Future<List<AsrSegment>> transcribeSegments(
    String wavPath, {
    void Function(double progress)? onProgress,
  }) async {
    if (throwOnTranscribe) throw StateError('boom');
    for (var i = 0; i < segments.length; i++) {
      onProgress?.call((i + 1) / segments.length);
    }
    return segments;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

/// 假引擎：transcribeSegments 永不完成（模拟阻塞的 native 推理），
/// 用于验证取消能打断在途 await 并触发清理。
class _HangingEngine implements OfflineAsrEngine {
  final _never = Completer<List<AsrSegment>>();
  int initializeCalls = 0;
  int disposeCalls = 0;

  @override
  String get name => 'hang';
  @override
  bool get isReady => initializeCalls > 0 && disposeCalls == 0;
  @override
  AsrModelInfo? get currentModel => null;

  @override
  Future<void> initialize(AsrModelConfig config) async {
    initializeCalls++;
  }

  @override
  Future<AsrResult> transcribe(String wavPath) async =>
      const AsrResult(text: '', inferenceTime: Duration.zero);

  @override
  Future<List<AsrSegment>> transcribeSegments(
    String wavPath, {
    void Function(double progress)? onProgress,
  }) => _never.future; // 永不完成

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

/// 假转码：写一个占位文件并返回预设结果，记录调用。
class _FakeTranscode extends AudioTranscodeService {
  _FakeTranscode({this.ok = true});
  final bool ok;
  int calls = 0;

  @override
  Future<bool> transcodeToPcmWav16k({
    required File source,
    required File output,
  }) async {
    calls++;
    if (ok) {
      await output.parent.create(recursive: true);
      await output.writeAsBytes([0, 0, 0, 0]);
    }
    return ok;
  }
}

/// 分段结果由测试控制的引擎：用于在识别期间插入用户操作。
class _GatedEngine implements OfflineAsrEngine {
  _GatedEngine(this.gate);

  final Completer<List<AsrSegment>> gate;
  int disposeCalls = 0;

  @override
  String get name => 'gated';
  @override
  bool get isReady => true;
  @override
  AsrModelInfo? get currentModel => null;

  @override
  Future<void> initialize(AsrModelConfig config) async {}

  @override
  Future<AsrResult> transcribe(String wavPath) async =>
      const AsrResult(text: '', inferenceTime: Duration.zero);

  @override
  Future<List<AsrSegment>> transcribeSegments(
    String wavPath, {
    void Function(double progress)? onProgress,
  }) => gate.future;

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

/// 可控提交时机的 DAO：只改写提交入口的时序，事务与写入仍走真实实现。
///
/// [writeBeforeGate] 为 true 时先在事务里写入再挂起，用于验证「提交已开始后
/// 取消以事务结果为准」；否则先挂起，用于验证「提交前取消不写入」。
class _CommitGateDao extends AudioItemDao {
  _CommitGateDao(super.db, {this.writeBeforeGate = false});

  final bool writeBeforeGate;

  /// 流水线已到达提交入口。
  final commitReached = Completer<void>();
  final _release = Completer<void>();

  /// 放行提交。
  void release() => _release.complete();

  @override
  Future<TranscriptCommitResult> commitTranscription({
    required String audioItemId,
    required String srt,
    required String? wordTimestampsJson,
    required int transcriptSource,
    required int? transcriptWordTimingSource,
    required String? transcriptLanguage,
    required int sentenceCount,
    required int wordCount,
    required String? expectedSrt,
    required bool Function() isCancelled,
  }) async {
    if (!writeBeforeGate) {
      commitReached.complete();
      await _release.future;
    }
    final result = await super.commitTranscription(
      audioItemId: audioItemId,
      srt: srt,
      wordTimestampsJson: wordTimestampsJson,
      transcriptSource: transcriptSource,
      transcriptWordTimingSource: transcriptWordTimingSource,
      transcriptLanguage: transcriptLanguage,
      sentenceCount: sentenceCount,
      wordCount: wordCount,
      expectedSrt: expectedSrt,
      isCancelled: isCancelled,
    );
    if (writeBeforeGate) {
      commitReached.complete();
      await _release.future;
    }
    return result;
  }
}

/// 假模型管理器：modelDir 返回临时目录，VAD 视为未下载（fake 引擎忽略 config）。
class _FakeModelManager extends AsrModelManager {
  _FakeModelManager(this._dir);
  final String _dir;
  @override
  Future<String> modelDir(String modelId) async => _dir;
  @override
  Future<bool> isModelDownloaded(String modelId) async => false;
}

AudioItem _testAudioItem({
  String id = 'a1',
  String audioPath = 'audios/x.m4a',
}) {
  return AudioItem(
    id: id,
    name: 'Test',
    audioPath: audioPath,
    addedDate: DateTime(2026),
    totalDuration: 60,
  );
}

Future<void> _seedRow(db.AppDatabase database, AudioItem item) async {
  await database
      .into(database.audioItems)
      .insert(
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
  late SharedPreferences prefs;

  setUp(() async {
    database = db.AppDatabase(NativeDatabase.memory());
    dataDir = await Directory.systemTemp.createTemp('local_tx_');
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    await database.close();
    if (await dataDir.exists()) await dataDir.delete(recursive: true);
  });

  ProviderContainer buildContainer({
    required OfflineAsrEngine engine,
    required _FakeTranscode transcode,
    List<AudioItem>? items,
    AudioItemDao? dao,
  }) {
    final fileOps = MockTranscriptionFileOps();
    when(() => fileOps.getDataDir()).thenAnswer((_) async => dataDir);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        sharedPreferencesProvider.overrideWithValue(prefs),
        if (dao != null) audioItemDaoProvider.overrideWithValue(dao),
        audioLibraryProvider.overrideWith(TestAudioLibrary.new),
        transcriptionFileOpsProvider.overrideWithValue(fileOps),
        localTranscriptionEngineFactoryProvider.overrideWithValue(() => engine),
        localTranscriptionTranscodeServiceProvider.overrideWithValue(transcode),
        asrModelManagerProvider.overrideWithValue(
          _FakeModelManager(dataDir.path),
        ),
      ],
    );
    (container.read(audioLibraryProvider.notifier) as TestAudioLibrary)
        .setItems(items ?? [_testAudioItem()]);
    return container;
  }

  final model = availableModels.first;

  group('LocalTranscriptionTaskManager', () {
    test('初始状态为空 Map', () {
      final container = buildContainer(
        engine: _FakeEngine(const []),
        transcode: _FakeTranscode(),
      );
      addTearDown(container.dispose);
      expect(container.read(localTranscriptionTaskManagerProvider), isEmpty);
    });

    test('完整流水线：解码→转录→写库→完成，专用引擎用后 dispose', () async {
      final item = _testAudioItem();
      await _seedRow(database, item);
      final engine = _FakeEngine([
        const AsrSegment(
          text: 'Hello world.',
          start: Duration(milliseconds: 200),
          end: Duration(milliseconds: 900),
        ),
        const AsrSegment(
          text: 'Second line.',
          start: Duration(milliseconds: 1000),
          end: Duration(milliseconds: 1800),
        ),
      ]);
      final transcode = _FakeTranscode();
      final container = buildContainer(
        engine: engine,
        transcode: transcode,
        items: [item],
      );
      addTearDown(container.dispose);

      final states = <LocalTranscriptionState>[];
      container.listen(
        localTranscriptionTaskManagerProvider.select((m) => m[item.id]),
        (_, next) {
          if (next != null) states.add(next);
        },
      );

      final notifier = container.read(
        localTranscriptionTaskManagerProvider.notifier,
      );
      // 关闭短句合并，验证两个完整句子分别入库。
      await notifier.startLocalTranscription(
        item,
        model: model,
        autoMergeShortSentences: false,
      );

      // 状态经历 Decoding → Transcribing → Completed。
      expect(states.any((s) => s is LocalTranscriptionDecoding), isTrue);
      expect(states.any((s) => s is LocalTranscriptionTranscribing), isTrue);
      expect(states.last, isA<LocalTranscriptionCompleted>());

      // 转码与引擎生命周期。
      expect(transcode.calls, 1);
      expect(engine.initializeCalls, 1);
      expect(engine.disposeCalls, 1); // 用后释放

      // SRT 写库含两段文本。
      final srt = await database.audioItemDao.getTranscriptSrt(item.id);
      expect(srt, isNotNull);
      expect(srt!, contains('Hello world'));
      expect(srt, contains('Second line'));

      // AudioItem 更新为 device 来源 + 英文。
      final updated = container
          .read(audioLibraryProvider)
          .audioItems
          .singleWhere((i) => i.id == item.id);
      expect(updated.transcriptSource, TranscriptSource.device);
      expect(updated.transcriptLanguage, 'en');
      expect(updated.sentenceCount, 2);

      // 临时 WAV 已清理。
      final tmpDir = Directory('${dataDir.path}/tmp/asr_transcribe');
      final leftover = tmpDir.existsSync()
          ? tmpDir.listSync().whereType<File>().toList()
          : <File>[];
      expect(leftover, isEmpty);
    });

    test('转录失败保留原音频、既有字幕与时间戳', () async {
      final item = _testAudioItem();
      await _seedRow(database, item);
      await database.audioItemDao.saveTranscriptContent(
        item.id,
        srt: 'original subtitles',
        wordTimestampsJson: 'original timestamps',
      );
      final source = File('${dataDir.path}/${item.audioPath}');
      await source.parent.create(recursive: true);
      await source.writeAsBytes([1, 2, 3, 4]);
      final container = buildContainer(
        engine: _FakeEngine(const [], throwOnTranscribe: true),
        transcode: _FakeTranscode(),
        items: [item],
      );
      addTearDown(container.dispose);
      await container
          .read(localTranscriptionTaskManagerProvider.notifier)
          .startLocalTranscription(item, model: model);
      expect(
        await database.audioItemDao.getTranscriptSrt(item.id),
        'original subtitles',
      );
      expect(
        await database.audioItemDao.getWordTimestamps(item.id),
        'original timestamps',
      );
      expect(await source.readAsBytes(), [1, 2, 3, 4]);
      expect(
        container.read(audioLibraryProvider).audioItems.single.audioPath,
        item.audioPath,
      );
    });

    test('提交成功：字幕、词时间戳、来源、语言与句词计数同事务落库，内存与数据库一致', () async {
      final item = _testAudioItem();
      await _seedRow(database, item);
      final container = buildContainer(
        engine: _FakeEngine(const [
          AsrSegment(
            text: 'Hello world.',
            start: Duration(milliseconds: 200),
            end: Duration(milliseconds: 900),
          ),
        ]),
        transcode: _FakeTranscode(),
        items: [item],
      );
      addTearDown(container.dispose);

      await container
          .read(localTranscriptionTaskManagerProvider.notifier)
          .startLocalTranscription(
            item,
            model: model,
            autoMergeShortSentences: false,
          );

      final row = await database.audioItemDao.getById(item.id);
      expect(row, isNotNull);
      expect(row!.transcriptSrt, contains('Hello world'));
      expect(row.wordTimestampsJson, isNotNull);
      expect(row.transcriptSource, TranscriptSource.device.index);
      expect(row.transcriptLanguage, 'en');
      expect(row.sentenceCount, 1);
      expect(row.wordCount, 2);

      // 事务提交后才刷新内存，两者描述同一次成功结果。
      final memory = container.read(audioLibraryProvider).audioItems.single;
      expect(memory.transcriptSource, TranscriptSource.device);
      expect(memory.transcriptLanguage, 'en');
      expect(memory.sentenceCount, row.sentenceCount);
      expect(memory.wordCount, row.wordCount);
    });

    test('识别期间用户导入字幕：提交冲突，保留用户较新的字幕并提示冲突', () async {
      final item = _testAudioItem();
      await _seedRow(database, item);
      final gate = Completer<List<AsrSegment>>();
      final container = buildContainer(
        engine: _GatedEngine(gate),
        transcode: _FakeTranscode(),
        items: [item],
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        localTranscriptionTaskManagerProvider.notifier,
      );

      final future = notifier.startLocalTranscription(item, model: model);
      for (
        var i = 0;
        i < 200 &&
            notifier.getTaskState(item.id) is! LocalTranscriptionTranscribing;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(
        notifier.getTaskState(item.id),
        isA<LocalTranscriptionTranscribing>(),
      );

      // 用户在识别期间导入新字幕（与导入主干一样先写入字幕内容）。
      await database.audioItemDao.saveTranscriptContent(
        item.id,
        srt: 'user imported subtitles',
        wordTimestampsJson: 'user imported words',
      );

      gate.complete(const [
        AsrSegment(
          text: 'Model text.',
          start: Duration(milliseconds: 200),
          end: Duration(milliseconds: 900),
        ),
      ]);
      await future;

      expect(
        await database.audioItemDao.getTranscriptSrt(item.id),
        'user imported subtitles',
      );
      expect(
        await database.audioItemDao.getWordTimestamps(item.id),
        'user imported words',
      );
      expect(
        notifier.getTaskState(item.id),
        isA<LocalTranscriptionConflict>(),
      );
      // 内存条目未被本次识别结果覆盖。
      final memory = container.read(audioLibraryProvider).audioItems.single;
      expect(memory.sentenceCount, 0);
      expect(memory.transcriptSource, isNull);
    });

    test('提交前取消：事务不写入，保持用户已有字幕与已取消状态', () async {
      final item = _testAudioItem();
      await _seedRow(database, item);
      await database.audioItemDao.saveTranscriptContent(
        item.id,
        srt: 'original subtitles',
        wordTimestampsJson: 'original timestamps',
      );
      final dao = _CommitGateDao(database);
      final container = buildContainer(
        engine: _FakeEngine(const [
          AsrSegment(
            text: 'Model text.',
            start: Duration(milliseconds: 200),
            end: Duration(milliseconds: 900),
          ),
        ]),
        transcode: _FakeTranscode(),
        items: [item],
        dao: dao,
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        localTranscriptionTaskManagerProvider.notifier,
      );

      final future = notifier.startLocalTranscription(item, model: model);
      await dao.commitReached.future;
      // 事务尚未写入时用户取消。
      notifier.cancelTranscription(item.id);
      dao.release();
      await future;

      expect(
        await database.audioItemDao.getTranscriptSrt(item.id),
        'original subtitles',
      );
      expect(
        await database.audioItemDao.getWordTimestamps(item.id),
        'original timestamps',
      );
      expect(notifier.getTaskState(item.id), isA<LocalTranscriptionIdle>());
    });

    test('提交已开始后取消：以事务结果为准，不出现报取消但字幕被覆盖', () async {
      final item = _testAudioItem();
      await _seedRow(database, item);
      final dao = _CommitGateDao(database, writeBeforeGate: true);
      final container = buildContainer(
        engine: _FakeEngine(const [
          AsrSegment(
            text: 'Model text.',
            start: Duration(milliseconds: 200),
            end: Duration(milliseconds: 900),
          ),
        ]),
        transcode: _FakeTranscode(),
        items: [item],
        dao: dao,
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        localTranscriptionTaskManagerProvider.notifier,
      );

      final future = notifier.startLocalTranscription(item, model: model);
      await dao.commitReached.future;
      // 事务已写入，此时取消不能把界面留在「已取消」。
      notifier.cancelTranscription(item.id);
      dao.release();
      await future;

      expect(
        await database.audioItemDao.getTranscriptSrt(item.id),
        contains('Model text'),
      );
      expect(
        notifier.getTaskState(item.id),
        isA<LocalTranscriptionCompleted>(),
      );
    });

    test('数据库写入失败：回滚字幕与元数据，保留原媒体与界面状态', () async {
      final item = _testAudioItem();
      await _seedRow(database, item);
      await database.audioItemDao.saveTranscriptContent(
        item.id,
        srt: 'original subtitles',
        wordTimestampsJson: 'original timestamps',
      );
      final source = File('${dataDir.path}/${item.audioPath}');
      await source.parent.create(recursive: true);
      await source.writeAsBytes([1, 2, 3, 4]);
      await database.learningProgressDao.upsert(
        db.LearningProgressesCompanion(
          audioItemId: Value(item.id),
          updatedAt: Value(DateTime(2026)),
        ),
      );
      // 用真实 SQLite 触发器让提交事务内的写入失败（模拟磁盘/元数据写入错误）。
      await database.customStatement(
        'CREATE TRIGGER fail_device_transcript BEFORE UPDATE ON audio_items '
        "WHEN NEW.transcript_source = ${TranscriptSource.device.index} "
        "BEGIN SELECT RAISE(ABORT, 'write failed'); END",
      );
      final container = buildContainer(
        engine: _FakeEngine(const [
          AsrSegment(
            text: 'Model text.',
            start: Duration(milliseconds: 200),
            end: Duration(milliseconds: 900),
          ),
        ]),
        transcode: _FakeTranscode(),
        items: [item],
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        localTranscriptionTaskManagerProvider.notifier,
      );

      await runZoned<Future<void>>(
        () => notifier.startLocalTranscription(item, model: model),
        zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
      );

      expect(notifier.getTaskState(item.id), isA<LocalTranscriptionFailed>());
      expect(
        await database.audioItemDao.getTranscriptSrt(item.id),
        'original subtitles',
      );
      expect(
        await database.audioItemDao.getWordTimestamps(item.id),
        'original timestamps',
      );
      // 来源、语言与句词计数未随失败提交部分写入。
      final row = await database.audioItemDao.getById(item.id);
      expect(row!.transcriptSource, isNull);
      expect(row.transcriptLanguage, isNull);
      expect(row.sentenceCount, 0);
      expect(row.wordCount, 0);
      // 界面内存条目保持原样，学习记录与原始媒体未被删除。
      final memory = container.read(audioLibraryProvider).audioItems.single;
      expect(memory.transcriptSource, isNull);
      expect(memory.sentenceCount, 0);
      expect(memory.audioPath, item.audioPath);
      expect(await source.readAsBytes(), [1, 2, 3, 4]);
      expect(
        await database.learningProgressDao.getByAudioId(item.id),
        isNotNull,
      );
    });

    test('历史 auto 字幕仅展示，不发起转录覆盖', () async {
      final item = _testAudioItem().copyWith(transcriptLanguage: 'auto');
      final engine = _FakeEngine(const []);
      final transcode = _FakeTranscode();
      final container = buildContainer(
        engine: engine,
        transcode: transcode,
        items: [item],
      );
      addTearDown(container.dispose);
      await container
          .read(localTranscriptionTaskManagerProvider.notifier)
          .startLocalTranscription(item, model: model);
      expect(transcode.calls, 0);
      expect(engine.initializeCalls, 0);
    });

    test('空分段 → EmptyResult，不写库', () async {
      final item = _testAudioItem();
      await _seedRow(database, item);
      final engine = _FakeEngine(const []);
      final container = buildContainer(
        engine: engine,
        transcode: _FakeTranscode(),
        items: [item],
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        localTranscriptionTaskManagerProvider.notifier,
      );

      await notifier.startLocalTranscription(item, model: model);

      expect(
        notifier.getTaskState(item.id),
        isA<LocalTranscriptionEmptyResult>(),
      );
      expect(await database.audioItemDao.getTranscriptSrt(item.id), isNull);
      expect(engine.disposeCalls, 1);
    });

    test('解码失败 → Failed(decode)，不初始化引擎', () async {
      final item = _testAudioItem();
      final engine = _FakeEngine(const []);
      final container = buildContainer(
        engine: engine,
        transcode: _FakeTranscode(ok: false),
        items: [item],
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        localTranscriptionTaskManagerProvider.notifier,
      );

      await notifier.startLocalTranscription(item, model: model);

      final state = notifier.getTaskState(item.id);
      expect(state, isA<LocalTranscriptionFailed>());
      expect((state as LocalTranscriptionFailed).code, 'decode');
      expect(engine.initializeCalls, 0);
    });

    test('转录抛异常 → Failed(unknown)，引擎仍被 dispose', () async {
      final item = _testAudioItem();
      final engine = _FakeEngine(const [], throwOnTranscribe: true);
      final container = buildContainer(
        engine: engine,
        transcode: _FakeTranscode(),
        items: [item],
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        localTranscriptionTaskManagerProvider.notifier,
      );

      await runZoned<Future<void>>(
        () => notifier.startLocalTranscription(item, model: model),
        zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
      );

      expect(notifier.getTaskState(item.id), isA<LocalTranscriptionFailed>());
      expect(engine.disposeCalls, 1);
    });

    test('进行中防重入：Transcribing 态忽略新请求', () async {
      final transcode = _FakeTranscode();
      final container = buildContainer(
        engine: _FakeEngine(const []),
        transcode: transcode,
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        localTranscriptionTaskManagerProvider.notifier,
      );
      notifier.state = {
        'a1': const LocalTranscriptionTranscribing(progress: 0.3),
      };

      await notifier.startLocalTranscription(_testAudioItem(), model: model);

      // 状态未被覆盖、未触发新一轮转码。
      expect(
        notifier.getTaskState('a1'),
        isA<LocalTranscriptionTranscribing>(),
      );
      expect(transcode.calls, 0);
    });

    test('取消在途转录：打断 await → 状态 Idle、dispose 引擎、清理临时 WAV', () async {
      final item = _testAudioItem();
      await _seedRow(database, item);
      final engine = _HangingEngine();
      final container = buildContainer(
        engine: engine,
        transcode: _FakeTranscode(),
        items: [item],
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        localTranscriptionTaskManagerProvider.notifier,
      );

      // 不 await：transcribeSegments 会一直挂起。
      final future = notifier.startLocalTranscription(item, model: model);

      // 轮询等待进入「转录中」（此时正阻塞在 transcribeSegments 的 await）。
      for (
        var i = 0;
        i < 200 &&
            notifier.getTaskState(item.id) is! LocalTranscriptionTranscribing;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(
        notifier.getTaskState(item.id),
        isA<LocalTranscriptionTranscribing>(),
      );

      // 取消应立即打断 await，主流程走 finally 清理。
      notifier.cancelTranscription(item.id);
      await future;

      expect(notifier.getTaskState(item.id), isA<LocalTranscriptionIdle>());
      expect(engine.disposeCalls, 1);

      // 临时 WAV 已删除。
      final tmpDir = Directory('${dataDir.path}/tmp/asr_transcribe');
      final leftover = tmpDir.existsSync()
          ? tmpDir.listSync().whereType<File>().toList()
          : <File>[];
      expect(leftover, isEmpty);
    });

    test('cancelTranscription 将状态重置为 Idle', () {
      final container = buildContainer(
        engine: _FakeEngine(const []),
        transcode: _FakeTranscode(),
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        localTranscriptionTaskManagerProvider.notifier,
      );
      notifier.state = {'a1': const LocalTranscriptionDecoding()};
      notifier.cancelTranscription('a1');
      expect(notifier.getTaskState('a1'), isA<LocalTranscriptionIdle>());
    });

    test('clearState 从 Map 中移除条目', () {
      final container = buildContainer(
        engine: _FakeEngine(const []),
        transcode: _FakeTranscode(),
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        localTranscriptionTaskManagerProvider.notifier,
      );
      notifier.state = {'a1': const LocalTranscriptionCompleted()};
      notifier.clearState('a1');
      expect(container.read(localTranscriptionTaskManagerProvider), isEmpty);
    });

    for (final autoMerge in [false, true]) {
      test('模型将长句切成多段时，入库保持完整句子（合并短句=$autoMerge）', () async {
        final item = _testAudioItem();
        await _seedRow(database, item);
        final engine = _FakeEngine(const [
          AsrSegment(
            text:
                'Americans angry over high prices are deciding whether to shift power',
            start: Duration(milliseconds: 200),
            end: Duration(milliseconds: 6500),
          ),
          AsrSegment(
            text: 'in Washington.',
            start: Duration(milliseconds: 6500),
            end: Duration(milliseconds: 7800),
          ),
          AsrSegment(
            text: 'The next sentence stays separate.',
            start: Duration(seconds: 8),
            end: Duration(seconds: 10),
          ),
        ]);
        final container = buildContainer(
          engine: engine,
          transcode: _FakeTranscode(),
          items: [item],
        );
        addTearDown(container.dispose);
        await container
            .read(localTranscriptionTaskManagerProvider.notifier)
            .startLocalTranscription(
              item,
              model: model,
              autoMergeShortSentences: autoMerge,
            );

        final srt = await database.audioItemDao.getTranscriptSrt(item.id);
        expect(
          srt,
          contains(
            '00:00:00,200 --> 00:00:07,800\n'
            'Americans angry over high prices are deciding whether to shift power in Washington.',
          ),
        );
        expect(srt, contains('The next sentence stays separate.'));
        final updated = container.read(audioLibraryProvider).audioItems.single;
        expect(updated.sentenceCount, 2);
        expect(updated.wordCount, 18);
      });
    }

    test('autoMerge 开启：相邻短段合并为一句写库', () async {
      final item = _testAudioItem();
      await _seedRow(database, item);
      // 三段各 <4s，合并后应收敛为一句。
      final engine = _FakeEngine([
        const AsrSegment(
          text: 'Hello',
          start: Duration(milliseconds: 0),
          end: Duration(milliseconds: 800),
        ),
        const AsrSegment(
          text: 'world',
          start: Duration(milliseconds: 900),
          end: Duration(milliseconds: 1700),
        ),
        const AsrSegment(
          text: 'again',
          start: Duration(milliseconds: 1800),
          end: Duration(milliseconds: 2600),
        ),
      ]);
      final container = buildContainer(
        engine: engine,
        transcode: _FakeTranscode(),
        items: [item],
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        localTranscriptionTaskManagerProvider.notifier,
      );

      await notifier.startLocalTranscription(
        item,
        model: model,
        autoMergeShortSentences: true,
      );

      final srt = await database.audioItemDao.getTranscriptSrt(item.id);
      expect(srt, contains('Hello world again'));
      final updated = container
          .read(audioLibraryProvider)
          .audioItems
          .singleWhere((i) => i.id == item.id);
      expect(updated.sentenceCount, 1);
    });
  });

  group('restoreAsrSentences', () {
    AsrSegment segment(String text, int start, int end) => AsrSegment(
      text: text,
      start: Duration(milliseconds: start),
      end: Duration(milliseconds: end),
    );

    test('跨片段长句接回句末，同片段的下一句不随之合入，末尾残句不丢', () {
      final result = restoreAsrSentences([
        segment('The story continues across', 0, 5000),
        segment(
          'two windows. Next question? Tail without punctuation',
          5000,
          10000,
        ),
      ]);
      expect(result.map((sentence) => sentence.text), [
        'The story continues across two windows.',
        'Next question?',
        'Tail without punctuation',
      ]);
      expect(result.first.start, Duration.zero);
      expect(result.last.end, const Duration(seconds: 10));
      for (var index = 1; index < result.length; index++) {
        expect(
          result[index].start,
          greaterThanOrEqualTo(result[index - 1].end),
        );
      }
    });

    test('小数、网址和称谓不拆句，引号后的句末能识别且全部文字守恒', () {
      const text = 'Dr. Brown paid 3.14 at example.com. “Really?!” Yes.';
      final result = restoreAsrSentences([segment(text, 1000, 9000)]);
      expect(result.map((sentence) => sentence.text), [
        'Dr. Brown paid 3.14 at example.com.',
        '“Really?!”',
        'Yes.',
      ]);
      expect(result.map((sentence) => sentence.text).join(' '), text);
      expect(result.first.start, const Duration(seconds: 1));
      expect(result.last.end, const Duration(seconds: 9));
    });

    test('空片段跳过，整段没有标点的长文本保留全部词语', () {
      final words = List.generate(120, (index) => 'word$index').join(' ');
      final result = restoreAsrSentences([
        segment('', 0, 0),
        segment(words, 0, 60000),
        segment('  ', 60000, 61000),
      ]);
      expect(result.single.text, words);
      expect(result.single.end, const Duration(minutes: 1));
    });
  });

  group('mergeShortAsrSegments', () {
    AsrSegment seg(String text, int startMs, int endMs) => AsrSegment(
      text: text,
      start: Duration(milliseconds: startMs),
      end: Duration(milliseconds: endMs),
    );

    test('空列表 / 单段原样返回', () {
      expect(mergeShortAsrSegments(const []), isEmpty);
      final one = [seg('solo', 0, 500)];
      expect(mergeShortAsrSegments(one), same(one));
    });

    test('相邻短段合并到 ≥4s，文本空格拼接、区间取并', () {
      final result = mergeShortAsrSegments([
        seg('a', 0, 1500),
        seg('b', 1500, 3000),
        seg('c', 3000, 4500),
      ]);
      expect(result, hasLength(1));
      expect(result.single.text, 'a b c');
      expect(result.single.start, Duration.zero);
      expect(result.single.end, const Duration(milliseconds: 4500));
    });

    test('已达下限的段独立成句，不再拼接后续', () {
      final result = mergeShortAsrSegments([
        seg('long', 0, 5000), // ≥4s，独立收尾
        seg('x', 5000, 5500),
        seg('y', 5500, 6000),
      ]);
      expect(result.map((s) => s.text).toList(), ['long', 'x y']);
    });

    test('末尾残余短段保留（不丢弃）', () {
      final result = mergeShortAsrSegments([
        seg('a', 0, 4200), // ≥4s 收尾
        seg('tail', 4200, 4700), // 残余短段独立保留
      ]);
      expect(result.map((s) => s.text).toList(), ['a', 'tail']);
    });
  });

  group('识别设置变更与在途字幕任务', () {
    test('识别中先告知受影响任务，接受后才取消且旧结果不写库', () async {
      final item = _testAudioItem();
      await _seedRow(database, item);
      final gate = Completer<List<AsrSegment>>();
      final container = buildContainer(
        engine: _GatedEngine(gate),
        transcode: _FakeTranscode(),
        items: [item],
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        localTranscriptionTaskManagerProvider.notifier,
      );

      final future = notifier.startLocalTranscription(
        item,
        model: availableModels.first,
      );
      for (
        var i = 0;
        i < 200 &&
            notifier.getTaskState(item.id) is! LocalTranscriptionTranscribing;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(
        notifier.getTaskState(item.id),
        isA<LocalTranscriptionTranscribing>(),
      );

      final settings = container.read(recognitionSettingsProvider.notifier);
      final nextModel = availableModels[2];
      final declined = await settings.change(
        purpose: RecognitionPurpose.subtitle,
        selection: RecognitionSelection.local(nextModel.id),
      );
      expect(declined.applied, isFalse);
      expect(declined.affectedTasks, hasLength(1));
      expect(
        container.read(localTranscriptionTaskManagerProvider)[item.id],
        isA<LocalTranscriptionTranscribing>(),
        reason: '未确认前任务与配置都保持原样',
      );

      final accepted = await settings.change(
        purpose: RecognitionPurpose.subtitle,
        selection: RecognitionSelection.local(nextModel.id),
        cancelInFlight: true,
      );
      expect(accepted.applied, isTrue);
      expect(
        container.read(recognitionSettingsProvider).subtitle.localModelId,
        nextModel.id,
      );

      gate.complete(const [
        AsrSegment(
          text: 'Model text.',
          start: Duration(milliseconds: 200),
          end: Duration(milliseconds: 900),
        ),
      ]);
      await future;

      // 取消后迟到的识别结果不能写回字幕。
      expect(await database.audioItemDao.getTranscriptSrt(item.id), isNull);
      expect(
        notifier.getTaskState(item.id),
        isNot(isA<LocalTranscriptionCompleted>()),
      );
    });
  });
}
