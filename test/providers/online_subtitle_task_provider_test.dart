/// 长材料在线字幕任务测试。
///
/// 通过受控语音配置/能力记录、假转写客户端、假转码与真实内存数据库，覆盖准入、
/// 分块顺序上传、失败后只续试未完成块、静音跳过、空结果失败、真实重复句与跨块
/// 单词、真实时间偏移、取消、配置变化后的过期结果，以及临时音频清理。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:echo_loop/database/app_database.dart' as db;
import 'package:echo_loop/database/providers.dart';
import 'package:echo_loop/features/audio_import/audio_transcode_service.dart';
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
import 'package:path/path.dart' as p;
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
  _MemoryConfigStore({required this.config});

  SpeechConfig? config;
  String? apiKey = 'sk-test';
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
  bool segments = true;
  bool wordTimestamps = false;

  /// 与 [SpeechConfigStore.readCredentialVersion] 保持同步的凭据版本。
  String credentialVersion = _credentialVersion;

  String get identity => SpeechCapability.identityFor(
    kind: _config.kind,
    baseUrl: _config.baseUrl,
    modelId: _modelId,
    credentialVersion: credentialVersion,
  );

  @override
  Future<SpeechCapability?> read(String identity) async =>
      identity == this.identity
      ? SpeechCapability(
          identity: identity,
          text: true,
          segments: segments,
          wordTimestamps: wordTimestamps,
          validatedAt: DateTime(2026, 11, 7),
        )
      : null;
}

/// 受控转写客户端：记录每次上传的真实时长，按调用序号给出结果、阻塞或失败。
class _FakeClient extends SpeechTranscriptionClient {
  final List<({Duration duration, bool wordTimestamps})> calls = [];

  /// 第 n 次调用（从 0 开始）的行为；未设置时返回一句固定文本。
  Future<SpeechTranscriptionResult> Function(int index, Duration duration)?
  onCall;

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
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    final index = calls.length;
    calls.add((
      duration: audioDuration,
      wordTimestamps: requestWordTimestamps,
    ));
    final handler = onCall;
    if (handler != null) return handler(index, audioDuration);
    return _result('Hello world.', start: 0.2, end: 1.5);
  }
}

/// 一句话的识别结果，便于按块构造不同文本。
SpeechTranscriptionResult _result(
  String text, {
  double start = 0,
  double end = 2,
  List<SpeechTranscriptSegment>? segments,
  List<SpeechTranscriptWord> words = const [],
  bool wordsValid = false,
  double? reportedCost,
}) => SpeechTranscriptionResult(
  text: text,
  segments: segments ?? [SpeechTranscriptSegment(start: start, end: end, text: text)],
  words: words,
  segmentsValid: true,
  wordsValid: wordsValid,
  reportedCost: reportedCost,
);

/// 多句结果：每句按给定相对时间返回片段。
SpeechTranscriptionResult _resultOf(List<(String, double, double)> lines) =>
    SpeechTranscriptionResult(
      text: lines.map((line) => line.$1).join(' '),
      segments: [
        for (final line in lines)
          SpeechTranscriptSegment(start: line.$2, end: line.$3, text: line.$1),
      ],
      segmentsValid: true,
    );

/// 16 kHz 单声道 16 bit PCM；[amplitude] 为 0 时是确认无声的块。
Uint8List _pcmBytes(Duration duration, {int amplitude = 8000}) {
  final samples = duration.inMicroseconds * 16000 ~/ 1000000;
  final bytes = Uint8List(samples * 2);
  for (var i = 0; i < samples; i++) {
    final value = amplitude == 0 ? 0 : (i.isEven ? amplitude : -amplitude);
    bytes[i * 2] = value & 0xff;
    bytes[i * 2 + 1] = (value >> 8) & 0xff;
  }
  return bytes;
}

/// 假转码：按请求的区间写出对应时长的 PCM，记录每次提取的范围。
class _FakeTranscode extends AudioTranscodeService {
  final List<({Duration start, Duration? duration})> ranges = [];

  /// 这些起点提取出的块写成静音，用来验证确认无声的块被跳过。
  final Set<Duration> silentChunkStarts = {};

  /// 指定第 n 次（从 1 开始）提取挂起，直到 [gate] 完成。
  Completer<void>? gate;
  int? gateAtRange;

  final List<int> cancelledSessions = [];

  @override
  Future<bool> transcodeRangeToPcmWav16k({
    required File source,
    required File output,
    required Duration start,
    Duration? duration,
    void Function(int sessionId)? onSessionStarted,
  }) async {
    ranges.add((start: start, duration: duration));
    final sessionId = ranges.length;
    onSessionStarted?.call(sessionId);
    if (gate != null && gateAtRange == sessionId) await gate!.future;
    final span = duration ?? const Duration(minutes: 2);
    final amplitude = silentChunkStarts.contains(start) ? 0 : 8000;
    await output.parent.create(recursive: true);
    await output.writeAsBytes(_pcmBytes(span, amplitude: amplitude));
    return true;
  }

  @override
  Future<bool> transcodeToPcmWav16k({
    required File source,
    required File output,
  }) async {
    await output.parent.create(recursive: true);
    await output.writeAsBytes(
      _pcmBytes(const Duration(seconds: 1)),
    );
    return true;
  }

  @override
  void cancelSession(int sessionId) => cancelledSessions.add(sessionId);
}

class _FakeFileOps extends TranscriptionFileOps {
  _FakeFileOps(this.dir);

  final Directory dir;

  @override
  Future<Directory> getDataDir() async => dir;
}

AudioItem _audioItem({int totalDuration = 60}) => AudioItem(
  id: 'a1',
  name: 'Test',
  audioPath: 'audios/x.m4a',
  addedDate: DateTime(2026),
  totalDuration: totalDuration,
);

Future<void> _seedRow(db.AppDatabase database, AudioItem item) async {
  await database.into(database.audioItems).insert(
    db.AudioItemsCompanion.insert(
      id: item.id,
      name: item.name,
      audioPath: Value(item.audioPath),
      addedDate: item.addedDate,
      totalDuration: Value(item.totalDuration),
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

  Future<ProviderContainer> start(
    AudioItem item, {
    bool autoMergeShortSentences = true,
  }) async {
    await _seedRow(database, item);
    final container = buildContainer(item: item);
    addTearDown(container.dispose);
    await container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .startOnlineTranscription(
          item,
          autoMergeShortSentences: autoMergeShortSentences,
        );
    return container;
  }

  OnlineSubtitleTaskState? taskState(ProviderContainer container, AudioItem item) =>
      container.read(onlineSubtitleTaskManagerProvider)[item.id];

  test('单块材料：一次请求即提交在线字幕与估算词时间戳', () async {
    final item = _audioItem();
    final container = await start(item, autoMergeShortSentences: false);

    expect(client.calls, hasLength(1));
    expect(client.calls.single.wordTimestamps, isFalse, reason: '未验证词能力时不请求词参数');
    final state = taskState(container, item);
    expect(state, isA<OnlineSubtitleCompleted>());
    expect((state as OnlineSubtitleCompleted).reportedCost, isNull);
    expect(state.wordTimingSource, TranscriptWordTimingSource.estimated);

    final row = await database.audioItemDao.getById(item.id);
    expect(row?.transcriptSource, TranscriptSource.online.index);
    expect(row?.transcriptWordTimingSource, TranscriptWordTimingSource.estimated.index);
    expect(row?.transcriptSrt, contains('Hello world.'));
    expect(row?.transcriptLanguage, 'en');
    expect(
      container.read(onlineSubtitleTaskManagerProvider.notifier)
          .checkpointCountForTest,
      0,
      reason: '提交后不保留检查点',
    );
  });

  test('模型词时间戳全部对上文本时整份标记为模型提供', () async {
    capabilityStore.wordTimestamps = true;
    client.onCall = (_, _) async => _result(
      'Hello world.',
      start: 0,
      end: 2,
      words: const [
        SpeechTranscriptWord(word: 'Hello', start: 0.1, end: 0.8),
        SpeechTranscriptWord(word: 'world.', start: 0.9, end: 1.9),
      ],
      wordsValid: true,
    );
    final item = _audioItem();
    await start(item, autoMergeShortSentences: false);

    expect(client.calls.single.wordTimestamps, isTrue);
    final row = await database.audioItemDao.getById(item.id);
    expect(row?.transcriptWordTimingSource, TranscriptWordTimingSource.model.index);
    expect(await database.audioItemDao.getWordTimestamps(item.id), contains('Hello'));
  });

  test('配置未通过字幕能力验证时拒绝发送请求', () async {
    capabilityStore.segments = false;
    final item = _audioItem();
    final container = await start(item);

    expect(client.calls, isEmpty);
    expect(
      (taskState(container, item) as OnlineSubtitleFailed).reason,
      OnlineSubtitleFailureReason.notVerified,
    );
    expect((await database.audioItemDao.getById(item.id))?.transcriptSrt, isNull);
  });

  test('长材料分块顺序上传：两块成功后第三块失败，重试只发失败块', () async {
    // 240 秒 → 3 块（100s / 95.5s / 46.5s），全程没有可确认的静音，按硬切处理。
    client.onCall = (index, _) async => switch (index) {
      0 => _result('First part.'),
      1 => _result('Second part.'),
      2 => throw const SpeechTranscriptionException(
        SpeechTranscriptionErrorKind.timeout,
      ),
      _ => _result('Third part.'),
    };
    final item = _audioItem(totalDuration: 240);
    final container = await start(item, autoMergeShortSentences: false);

    expect(client.calls.map((c) => c.duration), const [
      Duration(seconds: 100),
      Duration(milliseconds: 95500),
      Duration(milliseconds: 46500),
    ]);
    final failed = taskState(container, item);
    expect(failed, isA<OnlineSubtitleFailed>());
    failed as OnlineSubtitleFailed;
    expect(failed.reason, OnlineSubtitleFailureReason.unknown);
    expect(failed.speechError?.kind, SpeechTranscriptionErrorKind.timeout);
    expect(failed.completedChunks, 2);
    expect(failed.totalChunks, 3);
    expect(failed.failedChunk, 3);
    expect(failed.retryable, isTrue, reason: '保留检查点后可只续试未完成块');
    expect(failed.mayHaveBeenCharged, isTrue, reason: '超时请求可能已被供应商计费');
    expect((await database.audioItemDao.getById(item.id))?.transcriptSrt, isNull);

    // 重开弹窗/换页面后仍能续试：只重发第三块，前两块不再上传。
    await container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .startOnlineTranscription(item, autoMergeShortSentences: false);

    expect(client.calls, hasLength(4));
    expect(client.calls.last.duration, const Duration(milliseconds: 46500));
    expect(taskState(container, item), isA<OnlineSubtitleCompleted>());
    final srt = (await database.audioItemDao.getById(item.id))?.transcriptSrt;
    expect(srt, contains('First part.'));
    expect(srt, contains('Second part.'));
    expect(srt, contains('Third part.'));
  });

  test('硬切重叠区里重复识别的句子只保留一份，远处真实重复句保留', () async {
    client.onCall = (index, _) async => switch (index) {
      0 => _resultOf([('Alpha sentence.', 0, 50), ('Thank you.', 98, 99.9)]),
      1 => _resultOf([
        ('Thank you.', 0, 0.9),
        ('Beta sentence.', 10, 20),
        ('Alpha sentence.', 30, 40),
      ]),
      _ => _resultOf([('Gamma sentence.', 10, 20)]),
    };
    final item = _audioItem(totalDuration: 240);
    await start(item, autoMergeShortSentences: false);

    final srt = (await database.audioItemDao.getById(item.id))?.transcriptSrt;
    expect('Thank you.'.allMatches(srt ?? ''), hasLength(1), reason: '重叠区只留一份');
    // 远处真实重复的句子不能被全文去重删掉。
    expect('Alpha sentence.'.allMatches(srt ?? ''), hasLength(2));
    expect(srt, contains('Beta sentence.'));
  });

  test('跨块单词保留：上一块尾部与下一块开头不是同一段文本时一句都不删', () async {
    client.onCall = (index, _) async => switch (index) {
      0 => _resultOf([('Alpha sentence.', 0, 50), ('We keep the', 98, 100)]),
      _ => _resultOf([('word continues.', 0.2, 1.2), ('Next part.', 10, 20)]),
    };
    final item = _audioItem(totalDuration: 240);
    await start(item, autoMergeShortSentences: false);

    final srt = (await database.audioItemDao.getById(item.id))?.transcriptSrt;
    expect(srt, contains('We keep the'));
    expect(srt, contains('word continues.'));
    expect(srt, contains('Next part.'));
  });

  test('字幕时间使用真实块偏移', () async {
    client.onCall = (index, _) async => switch (index) {
      0 => _resultOf([('First part.', 0, 10)]),
      1 => _resultOf([('Second part.', 10, 20)]),
      _ => _resultOf([('Third part.', 10, 20)]),
    };
    final item = _audioItem(totalDuration: 240);
    await start(item, autoMergeShortSentences: false);

    final srt = (await database.audioItemDao.getById(item.id))?.transcriptSrt ?? '';
    // 第二块真实起点 99s，块内 10s → 109s；第三块起点 193.5s → 203.5s。
    expect(srt, contains('00:01:49'));
    expect(srt, contains('00:03:23,500'));
  });

  test('确认无声的块跳过上传，其余块正常合并提交', () async {
    // 中间那块（起点 99s）写静音 PCM：不发送请求，也不让它冒充失败。
    transcode.silentChunkStarts.add(const Duration(seconds: 99));
    client.onCall = (index, _) async =>
        _result(index == 0 ? 'First part.' : 'Third part.');
    final item = _audioItem(totalDuration: 240);
    final container = await start(item, autoMergeShortSentences: false);

    expect(client.calls, hasLength(2));
    expect(taskState(container, item), isA<OnlineSubtitleCompleted>());
    final srt = (await database.audioItemDao.getById(item.id))?.transcriptSrt;
    expect(srt, contains('First part.'));
    expect(srt, contains('Third part.'));
  });

  test('整份无语音时报告无可识别语音，不覆盖已有字幕', () async {
    transcode.silentChunkStarts.addAll([
      Duration.zero,
      const Duration(seconds: 99),
      const Duration(milliseconds: 193500),
    ]);
    final item = _audioItem(totalDuration: 240);
    final container = await start(item);

    expect(client.calls, isEmpty);
    expect(taskState(container, item), isA<OnlineSubtitleNoSpeech>());
    expect((await database.audioItemDao.getById(item.id))?.transcriptSrt, isNull);
  });

  test('有声块返回空结果时失败，不把语音内容当成静音跳过', () async {
    client.onCall = (_, _) async =>
        const SpeechTranscriptionResult(text: '   ', segmentsValid: false);
    final item = _audioItem();
    final container = await start(item);

    final failed = taskState(container, item) as OnlineSubtitleFailed;
    expect(failed.reason, OnlineSubtitleFailureReason.invalidResult);
    expect(failed.retryable, isTrue);
    expect(failed.mayHaveBeenCharged, isTrue, reason: '请求已发出，可能已计费');
    expect((await database.audioItemDao.getById(item.id))?.transcriptSrt, isNull);
  });

  test('识别期间用户另行导入字幕时保留用户内容并报告冲突', () async {
    final gate = Completer<void>();
    final firstCall = Completer<void>();
    client.onCall = (_, _) async {
      if (!firstCall.isCompleted) firstCall.complete();
      await gate.future;
      return _result('Hello world.');
    };
    final item = _audioItem();
    await _seedRow(database, item);
    final container = buildContainer(item: item);
    addTearDown(container.dispose);

    final pending = container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .startOnlineTranscription(item, autoMergeShortSentences: false);
    await firstCall.future;
    await database.audioItemDao.saveTranscriptContent(
      item.id,
      srt: '1\n00:00:00,000 --> 00:00:01,000\nUser import\n',
      wordTimestampsJson: null,
    );
    gate.complete();
    await pending;

    expect(taskState(container, item), isA<OnlineSubtitleConflict>());
    final row = await database.audioItemDao.getById(item.id);
    expect(row?.transcriptSrt, contains('User import'));
    expect(row?.transcriptSource, isNull);
    expect(
      container.read(onlineSubtitleTaskManagerProvider.notifier)
          .checkpointCountForTest,
      0,
    );
  });

  test('取消后不再发送后续块，清理临时结果且不写库', () async {
    final gate = Completer<void>();
    final firstCall = Completer<void>();
    client.onCall = (_, _) async {
      if (!firstCall.isCompleted) firstCall.complete();
      await gate.future;
      return _result('First part.');
    };
    final item = _audioItem(totalDuration: 240);
    await _seedRow(database, item);
    final container = buildContainer(item: item);
    addTearDown(container.dispose);

    final pending = container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .startOnlineTranscription(item, autoMergeShortSentences: false);
    await firstCall.future;
    container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .cancelTranscription(item.id);
    gate.complete();
    await pending;

    expect(client.calls, hasLength(1));
    expect(taskState(container, item), isA<OnlineSubtitleIdle>());
    expect(
      container.read(onlineSubtitleTaskManagerProvider.notifier)
          .checkpointCountForTest,
      0,
      reason: '取消后不留检查点',
    );
    final leftover = Directory(p.join(dataDir.path, 'tmp', 'online_subtitle'));
    expect(await leftover.exists() ? await leftover.list().isEmpty : true, isTrue);
    expect((await database.audioItemDao.getById(item.id))?.transcriptSrt, isNull);
  });

  test('请求期间配置变化时停止后续块，且不复用旧配置的已完成块', () async {
    final gate = Completer<void>();
    final firstCall = Completer<void>();
    client.onCall = (_, _) async {
      if (!firstCall.isCompleted) firstCall.complete();
      await gate.future;
      return _result('First part.');
    };
    final item = _audioItem(totalDuration: 240);
    await _seedRow(database, item);
    final container = buildContainer(item: item);
    addTearDown(container.dispose);

    final pending = container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .startOnlineTranscription(item, autoMergeShortSentences: false);
    await firstCall.future;
    configStore.credentialVersion = 'credential-b';
    gate.complete();
    await pending;

    expect(client.calls, hasLength(1), reason: '配置变化后不再发送后续块');
    final failed = taskState(container, item) as OnlineSubtitleFailed;
    expect(failed.reason, OnlineSubtitleFailureReason.configChanged);
    expect(failed.retryable, isFalse, reason: '旧配置的块不能续用');
    expect((await database.audioItemDao.getById(item.id))?.transcriptSrt, isNull);

    // 新配置下重试必须整份重新上传，不能拼接旧配置的结果。
    capabilityStore.credentialVersion = 'credential-b';
    client.onCall = (_, _) async => _result('Fresh part.');
    await container
        .read(onlineSubtitleTaskManagerProvider.notifier)
        .startOnlineTranscription(item, autoMergeShortSentences: false);

    expect(client.calls, hasLength(4), reason: '新配置重新发送全部 3 块');
  });
}
