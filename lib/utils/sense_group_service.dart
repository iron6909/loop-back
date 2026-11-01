/// 意群数据服务
///
/// 纯数据类，封装词级时间戳加载、AI 意群拆分请求和时间范围计算。
/// 不包含 UI 状态或播放逻辑，由 [SentenceExplanationView] 内部使用。
library;

import 'package:dio/dio.dart';

import '../database/daos/audio_item_dao.dart';
import '../models/sense_group_result.dart';
import '../models/word_timestamp.dart';
import '../providers/sentence_ai_provider.dart';
import 'sense_group_timing.dart';
import 'synthetic_word_timestamps.dart';

/// 意群数据服务
class SenseGroupService {
  /// 加载本地词级时间戳；缺失时从既有 SRT 合成，不再访问后端。
  ///
  /// 返回词级时间戳列表，无数据时返回 null。
  Future<List<WordTimestamp>?> fetchWordTimestamps({
    required String audioItemId,
    required AudioItemDao dao,
  }) async {
    final audioItem = await dao.getById(audioItemId);
    if (audioItem == null) return null;

    // 1. 优先从 audio_items 表读取
    final json = audioItem.wordTimestampsJson;
    if (json != null) {
      final words = decodeWordTimestamps(json);
      if (words != null && words.isNotEmpty) return words;
      // JSON 解析失败，清除脏数据
      await dao.updateWordTimestamps(audioItemId, null);
    }

    final srt =
        audioItem.transcriptSrt ?? await dao.getTranscriptSrt(audioItemId);
    if (srt == null || srt.isEmpty) return null;
    final words = await generateSyntheticWordTimestampsFromSrt(srt);
    if (words.isEmpty) return null;
    await dao.updateWordTimestamps(audioItemId, encodeWordTimestamps(words));
    return words;
  }

  /// 流式请求 AI 拆分意群
  ///
  /// 逐帧 yield（拆分结果, 对应 medium 时间范围）：medium 意群随流渐显，每帧按最新 medium
  /// 重算时间范围（有词级时间戳时精确匹配，否则按词数均分）。流结束（含 final）后自然结束。
  /// 缓存/计费/校验由 [SentenceAiNotifier.getSenseGroupsStream] 负责，本服务只做时间范围计算。
  Stream<(SenseGroupResult result, List<SenseGroupTiming> timings)>
  streamSenseGroups({
    required String text,
    required SentenceAiNotifier ai,
    required String? accessToken,
    required int sentenceStartMs,
    required int sentenceEndMs,
    List<WordTimestamp>? wordTimestamps,
    CancelToken? cancelToken,
    bool respectLocalQuotaReset = false,
  }) async* {
    final stream = ai.getSenseGroupsStream(
      text,
      accessToken: accessToken,
      cancelToken: cancelToken,
      respectLocalQuotaReset: respectLocalQuotaReset,
    );
    await for (final result in stream) {
      final timings = computeTimings(
        chunks: result.medium,
        wordTimestamps: wordTimestamps ?? const [],
        sentenceStartMs: sentenceStartMs,
        sentenceEndMs: sentenceEndMs,
      );
      yield (result, timings);
    }
  }

  /// 计算意群时间范围
  List<SenseGroupTiming> computeTimings({
    required List<String> chunks,
    required List<WordTimestamp> wordTimestamps,
    required int sentenceStartMs,
    required int sentenceEndMs,
  }) {
    // 找到句子在 words 中的范围
    var startIdx = 0;
    var endIdx = wordTimestamps.length - 1;

    for (var i = 0; i < wordTimestamps.length; i++) {
      if (wordTimestamps[i].startTime.inMilliseconds >= sentenceStartMs - 100) {
        startIdx = i;
        break;
      }
    }
    for (var i = wordTimestamps.length - 1; i >= 0; i--) {
      if (wordTimestamps[i].endTime.inMilliseconds <= sentenceEndMs + 100) {
        endIdx = i;
        break;
      }
    }

    return mapSenseGroupTimings(
      chunks: chunks,
      words: wordTimestamps,
      sentenceStart: Duration(milliseconds: sentenceStartMs),
      sentenceEnd: Duration(milliseconds: sentenceEndMs),
      sentenceStartWordIndex: startIdx,
      sentenceEndWordIndex: endIdx,
    );
  }
}
