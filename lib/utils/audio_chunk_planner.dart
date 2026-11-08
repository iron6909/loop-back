/// 长音频分块：把整段材料切成有界、顺序上传的切片，并处理相邻块的边界。
///
/// 切点优先落在邻近静音上：静音处切开不会截断句子，字幕时间只需加真实块偏移。
/// 找不到可确认的静音时按目标时长硬切，并给相邻两块留一小段重叠；重叠区里的
/// 重复识别通过 [trimChunkOverlap] 做局部对齐去掉，不做全文去重，避免误删材料里
/// 真实重复的句子。
///
/// 时长与字节上限是实施参数，不是用户可见选项：每块约两分钟只是首个工程验证
/// 目标，须按真实模型时延与供应商限制校准后固定在常量里。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../services/asr/offline_asr_engine.dart' show AsrSegment;

/// 每块目标时长。
const audioChunkTargetDuration = Duration(seconds: 100);

/// 每块时长硬上限：同时满足单次上传大小与供应商处理时限。
const audioChunkMaxDuration = Duration(minutes: 2);

/// 切点搜索半径：在目标时长前后各找这么宽，用来就近选静音。
const audioChunkCutSearchRadius = Duration(seconds: 20);

/// 硬切时相邻块的重叠时长；只覆盖边界附近，供局部对齐使用。
const audioChunkOverlap = Duration(seconds: 1);

/// 末块最少保留的时长，避免切出一段只值一次请求的碎片。
const _minTailDuration = Duration(seconds: 30);

/// 单块上传字节上限（16 kHz 单声道 16 bit WAV 两分钟约 3.84 MB，留出 multipart 余量）。
const audioChunkMaxUploadBytes = 4 * 1024 * 1024;

/// 16 kHz 单声道 16 bit PCM 的每秒字节数。
const _bytesPerSecond = 32000;

/// 16 kHz 单声道 16 bit PCM 的每秒采样数。
const _samplesPerSecond = 16000;

/// 静音探测的评估窗口；切点落在该窗口中心。
const _quietWindow = Duration(milliseconds: 300);

/// 可下刀的静音上限（RMS，满量程 32768，约 -31 dBFS）。
const _quietFloorRms = 900.0;

/// 与窗口内最响处的能量比：低不到该比例就不算静音，不做静音切分。
const _quietRatio = 0.25;

/// 整块判定无声的 RMS 上限（约 -49 dBFS）。
///
/// 只在整块能量低到该值时跳过上传：宁可上传可疑的块，也不能把有语音的内容当
/// 无声跳过。
const _silentChunkRms = 120.0;

/// 一个待上传的切片，时间相对整段材料。
class AudioChunk {
  const AudioChunk({
    required this.index,
    required this.start,
    required this.end,
    required this.hardCut,
  });

  /// 顺序上传用的块序号（从 0 开始）。
  final int index;

  /// 切片在整段材料中的绝对起点。
  final Duration start;

  /// 切片在整段材料中的绝对终点。
  final Duration end;

  /// 是否硬切：为真时本块尾部与下一块头部重叠一段，需要边界局部对齐。
  final bool hardCut;

  Duration get duration => end - start;
}

/// 探测 `[from, to]` 内最适合下刀的时刻；返回 null 表示无法确认静音。
typedef ChunkCutProbe = Future<Duration?> Function(Duration from, Duration to);

/// 顺序规划整段材料的分块方案。
///
/// 每块不超过 [audioChunkMaxDuration]，末块不短于 [_minTailDuration]（材料更短时
/// 只有一块）；切点由 [probe] 给出，探测不到静音或结果越界时按目标时长硬切。
Future<List<AudioChunk>> planAudioChunks({
  required Duration totalDuration,
  required ChunkCutProbe probe,
}) async {
  final chunks = <AudioChunk>[];
  var start = Duration.zero;
  var index = 0;
  while (start < totalDuration) {
    final remaining = totalDuration - start;
    if (remaining <= audioChunkMaxDuration) {
      chunks.add(
        AudioChunk(
          index: index,
          start: start,
          end: totalDuration,
          hardCut: false,
        ),
      );
      break;
    }
    final target = start + audioChunkTargetDuration;
    final earliest = target - audioChunkCutSearchRadius;
    var latest = target + audioChunkCutSearchRadius;
    final maxEnd = start + audioChunkMaxDuration;
    if (latest > maxEnd) latest = maxEnd;
    final tailLimited = totalDuration - _minTailDuration;
    if (latest > tailLimited) latest = tailLimited;

    var cut = await probe(earliest, latest);
    // 越界结果不能用：宁可硬切，也不接受不可解释的切点。
    if (cut != null && (cut <= earliest || cut >= latest)) cut = null;
    final hardCut = cut == null;
    final end = cut ?? earliest + (latest - earliest) ~/ 2;
    chunks.add(
      AudioChunk(index: index, start: start, end: end, hardCut: hardCut),
    );
    start = hardCut ? end - audioChunkOverlap : end;
    index++;
  }
  return chunks;
}

/// 在探测窗口的 PCM 里找最安静的一段，返回它的中心时刻。
///
/// 返回 null 表示窗口内没有可确认的静音：最安静处既不够低，也没有明显低于
/// 窗口内的最响处。两个阈值都是工程起点，需按真实材料与设备校准。
Duration? quietestCutInPcm({
  required Uint8List wavBytes,
  required Duration windowStart,
}) {
  final offset = pcmPayloadOffset(wavBytes);
  final windowSamples =
      _quietWindow.inMicroseconds * _samplesPerSecond ~/ 1000000;
  final totalSamples = (wavBytes.length - offset) ~/ 2;
  if (totalSamples < windowSamples) return null;

  double? quietest;
  var quietestIndex = 0;
  var loudest = 0.0;
  var index = 0;
  // 步进与窗口等长：静音区内任取一段都会命中，不必逐个采样平移。
  while (index + windowSamples <= totalSamples) {
    final rms = _rms(wavBytes, offset + index * 2, windowSamples);
    if (quietest == null || rms < quietest) {
      quietest = rms;
      quietestIndex = index;
    }
    if (rms > loudest) loudest = rms;
    index += windowSamples;
  }
  if (quietest == null || quietest > _quietFloorRms) return null;
  if (loudest > 0 && quietest > loudest * _quietRatio) return null;
  return windowStart +
      Duration(
        microseconds:
            (quietestIndex + windowSamples ~/ 2) * 1000000 ~/ _samplesPerSecond,
      );
}

/// 整块是否低到可以确认「没有语音」；空音频不当作无声，避免掩盖解码问题。
bool isSilentPcm(Uint8List wavBytes) {
  final offset = pcmPayloadOffset(wavBytes);
  final samples = (wavBytes.length - offset) ~/ 2;
  if (samples <= 0) return false;
  return _rms(wavBytes, offset, samples) < _silentChunkRms;
}

/// 16 kHz 单声道 16 bit PCM 的字节长度换算出的时长。
Duration pcmWavDuration(int byteLength) =>
    Duration(microseconds: byteLength * 1000000 ~/ _bytesPerSecond);

/// WAV 载荷起点：ffmpeg 输出的 44 字节标准头跳过，否则按裸 PCM 处理。
///
/// shortcut: 只认 44 字节标准头；出现附加块时按裸 PCM 处理，
/// 只会让静音探测偏几毫秒，不影响切点选择。
int pcmPayloadOffset(Uint8List bytes) {
  if (bytes.length < 44) return 0;
  const riff = [0x52, 0x49, 0x46, 0x46];
  for (var i = 0; i < riff.length; i++) {
    if (bytes[i] != riff[i]) return 0;
  }
  return 44;
}

/// 边界局部对齐：只在重叠区间内去掉下一块重复识别的前缀。
///
/// [previousTail] 是上一块落在重叠区间内的句子，[boundary] 是上一块的真实结束
/// 时刻。只有上一块尾部确实以本块开头这段词序结尾（同一段音频被两边都识别到）
/// 才丢弃重复的整句；跨在切点上的句子保留，避免丢掉被切开的单词。判断范围限于
/// 边界附近，所以材料里远处真实重复的句子不会被删。
List<AsrSegment> trimChunkOverlap({
  required List<AsrSegment> previousTail,
  required List<AsrSegment> next,
  required Duration boundary,
  Duration tolerance = const Duration(milliseconds: 250),
}) {
  if (previousTail.isEmpty || next.isEmpty) return next;
  final leading = <AsrSegment>[];
  for (final segment in next) {
    if (segment.end > boundary + tolerance) break;
    leading.add(segment);
  }
  if (leading.isEmpty) return next;
  final previousTokens = _tokens(previousTail);
  final leadingTokens = _tokens(leading);
  if (previousTokens.isEmpty || leadingTokens.isEmpty) return next;
  final matched = _commonSuffixPrefix(previousTokens, leadingTokens);
  if (matched == 0) return next;
  var droppedSentences = 0;
  var consumed = 0;
  for (final sentence in leading) {
    final count = _tokens([sentence]).length;
    if (consumed + count > matched) break;
    consumed += count;
    droppedSentences++;
  }
  return droppedSentences == 0 ? next : next.sublist(droppedSentences);
}

/// 纯文本块的边界局部对齐：去掉下一块开头重复识别的前缀单词。
///
/// 字幕能用句时间判断重叠区，练习录音只要求文本，因此按词序在边界处比对：
/// 只在上一块末尾与下一块开头最多 [maxOverlapWords] 个词的窗口内找最长相同词序，
/// 命中则从下一块删掉重复的那部分。比较窗口限定在边界附近，材料里远处真实重复
/// 的句子不会被误删，也不对全文做字符串去重。
String trimChunkTextOverlap({
  required String previousText,
  required String nextText,
  int maxOverlapWords = 16,
}) {
  if (previousText.trim().isEmpty || nextText.trim().isEmpty) return nextText;
  final nextMatches = RegExp(r'\S+').allMatches(nextText).toList();
  final previousTokens = _textTokens(previousText);
  final nextTokens = _textTokens(nextText);
  if (previousTokens.isEmpty || nextTokens.isEmpty) return nextText;
  // 只在边界窗口内比对：下一块开头最多取这么多词。
  final headLimit = nextMatches.length < maxOverlapWords
      ? nextMatches.length
      : maxOverlapWords;
  final headTokens = <String>[
    for (var i = 0; i < headLimit && i < nextTokens.length; i++) nextTokens[i],
  ];
  final tailStart = previousTokens.length > maxOverlapWords
      ? previousTokens.length - maxOverlapWords
      : 0;
  final matched = _commonSuffixPrefix(
    previousTokens.sublist(tailStart),
    headTokens,
  );
  if (matched == 0) return nextText;
  return nextText.substring(nextMatches[matched - 1].end).trimLeft();
}

/// 纯文本的比较词序：忽略大小写与标点，撇号保留（don't 仍是一个词）。
List<String> _textTokens(String text) {
  final tokens = <String>[];
  for (final match in RegExp(r'\S+').allMatches(text)) {
    final token = (match.group(0) ?? '').toLowerCase().replaceAll(
      RegExp(r"[^a-z0-9']"),
      '',
    );
    if (token.isNotEmpty) tokens.add(token);
  }
  return tokens;
}

/// 最长的一段「上一块尾部」与「本块开头」相同的词序长度。
int _commonSuffixPrefix(List<String> previous, List<String> leading) {
  final max = leading.length < previous.length
      ? leading.length
      : previous.length;
  for (var length = max; length > 0; length--) {
    var same = true;
    for (var i = 0; i < length; i++) {
      if (previous[previous.length - length + i] != leading[i]) {
        same = false;
        break;
      }
    }
    if (same) return length;
  }
  return 0;
}

/// 句子的比较词序：忽略大小写与标点，撇号保留（don't 仍是一个词）。
List<String> _tokens(List<AsrSegment> segments) {
  final tokens = <String>[];
  for (final segment in segments) {
    for (final match in RegExp(r'\S+').allMatches(segment.text)) {
      final token = (match.group(0) ?? '').toLowerCase().replaceAll(
        RegExp(r"[^a-z0-9']"),
        '',
      );
      if (token.isNotEmpty) tokens.add(token);
    }
  }
  return tokens;
}

/// 从小端 PCM16 的 [byteOffset] 起连续 [sampleCount] 个采样的均方根。
double _rms(Uint8List bytes, int byteOffset, int sampleCount) {
  if (sampleCount <= 0) return 0;
  final end = byteOffset + sampleCount * 2;
  if (end > bytes.length) return 0;
  var sum = 0.0;
  for (var i = byteOffset; i < end; i += 2) {
    final value = (bytes[i] | (bytes[i + 1] << 8)).toSigned(16);
    sum += value * value;
  }
  return math.sqrt(sum / sampleCount);
}
