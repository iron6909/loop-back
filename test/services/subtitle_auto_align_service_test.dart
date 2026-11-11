import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/models/word_timestamp.dart';
import 'package:loop_back/services/native_audio_decoder.dart';
import 'package:loop_back/services/subtitle_auto_align_service.dart';
import 'package:loop_back/utils/srt_generator.dart';

class _FakeNativeAudioDecoder implements NativeAudioDecoder {
  final bool supported;
  final DecodedAudioData? decodedAudioData;
  final Object? error;
  final bool neverComplete;

  const _FakeNativeAudioDecoder({
    required this.supported,
    this.decodedAudioData,
    this.error,
    this.neverComplete = false,
  });

  @override
  bool get isSupported => supported;

  @override
  Future<DecodedAudioData?> decode(String audioPath) async {
    if (neverComplete) {
      return Completer<DecodedAudioData?>().future;
    }
    if (error != null) {
      throw error!;
    }
    return decodedAudioData;
  }
}

/// 构造 [0, duration] 区间内恒定幅度的 PCM 段（1000 Hz 采样率）。
DecodedAudioData _buildAudio({
  required int sampleCount,
  List<({int start, int end, double amplitude})> segments = const [],
  int sampleRate = 1000,
}) {
  final samples = Float32List(sampleCount);
  for (final seg in segments) {
    for (var i = seg.start; i < seg.end && i < sampleCount; i++) {
      samples[i] = seg.amplitude;
    }
  }
  return DecodedAudioData(samples: samples, sampleRate: sampleRate);
}

void main() {
  group('SubtitleAutoAlignService', () {
    test('遇到句边界附近静音时会第一级回退、交由 150ms 对称兜底处理', () async {
      // 音频布局（1kHz 采样率，duration=2s）：
      // [0,100)    静音
      // [100,900)  响 0.5
      // [900,1100) 静音（200ms，对应 S0 end 和 S1 start 之间）
      // [1100,1900) 响 0.5
      // [1900,2000) 静音
      final decoded = _buildAudio(
        sampleCount: 2000,
        segments: const [
          (start: 100, end: 900, amplitude: 0.5),
          (start: 1100, end: 1900, amplitude: 0.5),
        ],
      );

      final service = SubtitleAutoAlignService(
        decoder: _FakeNativeAudioDecoder(
          supported: true,
          decodedAudioData: decoded,
        ),
      );

      final result = await service.alignIfPossible(
        audioPath: '/tmp/test.m4a',
        sentences: const [
          TranscriptSentence(
            text: 'Hello',
            startTime: Duration(milliseconds: 200),
            endTime: Duration(milliseconds: 800),
            startWordIndex: 0,
            endWordIndex: 0,
          ),
          TranscriptSentence(
            text: 'World',
            startTime: Duration(milliseconds: 1200),
            endTime: Duration(milliseconds: 1800),
            startWordIndex: 1,
            endWordIndex: 1,
          ),
        ],
        words: const [
          WordTimestamp(
            word: 'Hello',
            startTime: Duration(milliseconds: 250),
            endTime: Duration(milliseconds: 750),
          ),
          WordTimestamp(
            word: 'World',
            startTime: Duration(milliseconds: 1250),
            endTime: Duration(milliseconds: 1750),
          ),
        ],
      );

      expect(result, hasLength(2));
      // 首句起点：候选 [0,200ms] 内静音 [0,100ms]，padding=100 → 0ms。
      expect(result[0].startTime, const Duration(milliseconds: 0));
      // S0-S1 静音 [900,1100]，双向 padding 后 end=1000 / start=1000，
      // gap=0 < 50ms → 第一级整对回退，改走 150ms 对称兜底：
      // gap(400ms) - minGap(50) = 350ms 的 slack，每侧吃满 150ms。
      expect(result[0].endTime, const Duration(milliseconds: 950));
      expect(result[1].startTime, const Duration(milliseconds: 1050));
      // 末句终点：静音 [1900,2000]，padding=100 → 2000ms。
      expect(result[1].endTime, const Duration(milliseconds: 2000));
    });

    test('候选区间无静音但 gap 足够大时用 150ms 对称兜底', () async {
      // 整段均为 0.5，无静音可用。
      final decoded = _buildAudio(
        sampleCount: 2000,
        segments: const [(start: 0, end: 2000, amplitude: 0.5)],
      );

      final service = SubtitleAutoAlignService(
        decoder: _FakeNativeAudioDecoder(
          supported: true,
          decodedAudioData: decoded,
        ),
      );

      final result = await service.alignIfPossible(
        audioPath: '/tmp/test.m4a',
        sentences: const [
          TranscriptSentence(
            text: 'Hello',
            startTime: Duration(milliseconds: 200),
            endTime: Duration(milliseconds: 800),
            startWordIndex: 0,
            endWordIndex: 0,
          ),
          TranscriptSentence(
            text: 'World',
            startTime: Duration(milliseconds: 1000),
            endTime: Duration(milliseconds: 1800),
            startWordIndex: 1,
            endWordIndex: 1,
          ),
        ],
        words: const [
          WordTimestamp(
            word: 'Hello',
            startTime: Duration(milliseconds: 250),
            endTime: Duration(milliseconds: 750),
          ),
          WordTimestamp(
            word: 'World',
            startTime: Duration(milliseconds: 1050),
            endTime: Duration(milliseconds: 1750),
          ),
        ],
      );

      expect(result, hasLength(2));
      // gap=200ms，slack=150ms，双向对称各吃 75ms。
      expect(result[0].endTime, const Duration(milliseconds: 875));
      expect(result[1].startTime, const Duration(milliseconds: 925));
    });

    test('gap 本身小于最小间隙 (50ms) 时兜底也不生效，保持原值', () async {
      final decoded = _buildAudio(
        sampleCount: 2000,
        segments: const [(start: 0, end: 2000, amplitude: 0.5)],
      );

      final service = SubtitleAutoAlignService(
        decoder: _FakeNativeAudioDecoder(
          supported: true,
          decodedAudioData: decoded,
        ),
      );

      // S0.end=800, S1.start=830, gap=30ms < 50ms → fallback 返回 null。
      final result = await service.alignIfPossible(
        audioPath: '/tmp/test.m4a',
        sentences: const [
          TranscriptSentence(
            text: 'Hello',
            startTime: Duration(milliseconds: 200),
            endTime: Duration(milliseconds: 800),
            startWordIndex: 0,
            endWordIndex: 0,
          ),
          TranscriptSentence(
            text: 'World',
            startTime: Duration(milliseconds: 830),
            endTime: Duration(milliseconds: 1800),
            startWordIndex: 1,
            endWordIndex: 1,
          ),
        ],
        words: const [
          WordTimestamp(
            word: 'Hello',
            startTime: Duration(milliseconds: 250),
            endTime: Duration(milliseconds: 750),
          ),
          WordTimestamp(
            word: 'World',
            startTime: Duration(milliseconds: 850),
            endTime: Duration(milliseconds: 1750),
          ),
        ],
      );

      expect(result[0].endTime, const Duration(milliseconds: 800));
      expect(result[1].startTime, const Duration(milliseconds: 830));
    });

    test('解码器不支持时直接回退原始句边界', () async {
      final original = const [
        TranscriptSentence(
          text: 'Hello world',
          startTime: Duration(milliseconds: 200),
          endTime: Duration(milliseconds: 800),
          startWordIndex: 0,
          endWordIndex: 1,
        ),
      ];
      final service = SubtitleAutoAlignService(
        decoder: const _FakeNativeAudioDecoder(supported: false),
      );

      final result = await service.alignIfPossible(
        audioPath: '/tmp/test.m4a',
        sentences: original,
        words: const [
          WordTimestamp(
            word: 'Hello',
            startTime: Duration(milliseconds: 250),
            endTime: Duration(milliseconds: 500),
          ),
          WordTimestamp(
            word: 'world',
            startTime: Duration(milliseconds: 520),
            endTime: Duration(milliseconds: 760),
          ),
        ],
      );

      expect(result, same(original));
    });

    test('原生解码失败时只回退原始句边界', () async {
      final original = const [
        TranscriptSentence(
          text: 'Hello world',
          startTime: Duration(milliseconds: 200),
          endTime: Duration(milliseconds: 800),
          startWordIndex: 0,
          endWordIndex: 1,
        ),
      ];
      final service = SubtitleAutoAlignService(
        decoder: const _FakeNativeAudioDecoder(
          supported: true,
          error: NativeAudioDecoderException('decodeFailed', 'boom'),
        ),
      );

      final result = await service.alignIfPossible(
        audioPath: '/tmp/test.m4a',
        sentences: original,
        words: const [
          WordTimestamp(
            word: 'Hello',
            startTime: Duration(milliseconds: 250),
            endTime: Duration(milliseconds: 500),
          ),
          WordTimestamp(
            word: 'world',
            startTime: Duration(milliseconds: 520),
            endTime: Duration(milliseconds: 760),
          ),
        ],
      );

      expect(result, same(original));
    });

    test('原生解码卡住超过硬超时时回退原始句边界', () async {
      final original = const [
        TranscriptSentence(
          text: 'Hello world',
          startTime: Duration(milliseconds: 200),
          endTime: Duration(milliseconds: 800),
          startWordIndex: 0,
          endWordIndex: 1,
        ),
      ];
      final service = SubtitleAutoAlignService(
        decoder: const _FakeNativeAudioDecoder(
          supported: true,
          neverComplete: true,
        ),
        timeoutForDuration: (_) => const Duration(milliseconds: 10),
      );

      final result = await service.alignIfPossible(
        audioPath: '/tmp/test.m4a',
        sentences: original,
        words: const [
          WordTimestamp(
            word: 'Hello',
            startTime: Duration(milliseconds: 250),
            endTime: Duration(milliseconds: 500),
          ),
          WordTimestamp(
            word: 'world',
            startTime: Duration(milliseconds: 520),
            endTime: Duration(milliseconds: 760),
          ),
        ],
      );

      expect(result, same(original));
    });

    test('解码器抛 Error（非 Exception）时也回退原始句边界', () async {
      // 覆盖 StackOverflowError / StateError 等 Error 子类路径，
      // 确认服务层 catch 能接住所有继承 Object 的异常对象。
      final original = const [
        TranscriptSentence(
          text: 'Hello world',
          startTime: Duration(milliseconds: 200),
          endTime: Duration(milliseconds: 800),
          startWordIndex: 0,
          endWordIndex: 1,
        ),
      ];
      final service = SubtitleAutoAlignService(
        decoder: _FakeNativeAudioDecoder(
          supported: true,
          error: StateError('unexpected internal state'),
        ),
      );

      final result = await service.alignIfPossible(
        audioPath: '/tmp/test.m4a',
        sentences: original,
        words: const [
          WordTimestamp(
            word: 'Hello',
            startTime: Duration(milliseconds: 250),
            endTime: Duration(milliseconds: 500),
          ),
          WordTimestamp(
            word: 'world',
            startTime: Duration(milliseconds: 520),
            endTime: Duration(milliseconds: 760),
          ),
        ],
      );

      expect(result, same(original));
    });

    test('解码结果非法（sampleRate=0）时也回退原始句边界', () async {
      final original = const [
        TranscriptSentence(
          text: 'Hello world',
          startTime: Duration(milliseconds: 200),
          endTime: Duration(milliseconds: 800),
          startWordIndex: 0,
          endWordIndex: 1,
        ),
      ];
      final service = SubtitleAutoAlignService(
        decoder: _FakeNativeAudioDecoder(
          supported: true,
          decodedAudioData: DecodedAudioData(
            samples: Float32List(100),
            sampleRate: 0,
          ),
        ),
      );

      final result = await service.alignIfPossible(
        audioPath: '/tmp/test.m4a',
        sentences: original,
        words: const [
          WordTimestamp(
            word: 'Hello',
            startTime: Duration(milliseconds: 250),
            endTime: Duration(milliseconds: 500),
          ),
          WordTimestamp(
            word: 'world',
            startTime: Duration(milliseconds: 520),
            endTime: Duration(milliseconds: 760),
          ),
        ],
      );

      expect(result, hasLength(1));
      expect(result[0].startTime, original[0].startTime);
      expect(result[0].endTime, original[0].endTime);
    });

    test('句子数据部分非法（startWordIndex 越界）时整体回退', () async {
      final original = const [
        TranscriptSentence(
          text: 'Hello',
          startTime: Duration(milliseconds: 200),
          endTime: Duration(milliseconds: 800),
          startWordIndex: 99,
          endWordIndex: 99,
        ),
      ];
      final service = SubtitleAutoAlignService(
        decoder: _FakeNativeAudioDecoder(
          supported: true,
          decodedAudioData: DecodedAudioData(
            samples: Float32List(1000),
            sampleRate: 1000,
          ),
        ),
      );

      final result = await service.alignIfPossible(
        audioPath: '/tmp/test.m4a',
        sentences: original,
        words: const [
          WordTimestamp(
            word: 'Hello',
            startTime: Duration(milliseconds: 250),
            endTime: Duration(milliseconds: 750),
          ),
        ],
      );

      // _hasUsableWordBoundaries 前置检查拦截，整体回退。
      expect(result, same(original));
    });

    test('缺少可用词边界时直接回退原始句边界', () async {
      final original = const [
        TranscriptSentence(
          text: 'Hello world',
          startTime: Duration(milliseconds: 200),
          endTime: Duration(milliseconds: 800),
        ),
      ];
      final service = SubtitleAutoAlignService(
        decoder: _FakeNativeAudioDecoder(
          supported: true,
          decodedAudioData: DecodedAudioData(
            samples: Float32List(100),
            sampleRate: 1000,
          ),
        ),
      );

      final result = await service.alignIfPossible(
        audioPath: '/tmp/test.m4a',
        sentences: original,
        words: const [
          WordTimestamp(
            word: 'Hello',
            startTime: Duration(milliseconds: 250),
            endTime: Duration(milliseconds: 500),
          ),
        ],
      );

      expect(result, same(original));
    });
  });

  group('computeAutoAlignedSentenceBoundaries', () {
    TranscriptSentence sent(
      int startMs,
      int endMs, {
      int startWord = 0,
      int endWord = 0,
    }) {
      return TranscriptSentence(
        text: 't',
        startTime: Duration(milliseconds: startMs),
        endTime: Duration(milliseconds: endMs),
        startWordIndex: startWord,
        endWordIndex: endWord,
      );
    }

    WordTimestamp word(int startMs, int endMs) {
      return WordTimestamp(
        word: 'w',
        startTime: Duration(milliseconds: startMs),
        endTime: Duration(milliseconds: endMs),
      );
    }

    test('maxBoundaryShiftMs 钳制：提议位移大于 500ms 时截断', () {
      // 在 S0-S1 之间放一段极长的静音 [3600, 5000]ms，padding=100ms 会让
      // proposedEnd=3700、proposedStart=4900，相对 S0.end=2400 / S1.start=5500
      // 的位移分别为 +1300ms 与 -600ms，双侧都应被钳制到 ±500ms。
      final decoded = _buildAudio(
        sampleCount: 5500,
        segments: const [
          (start: 0, end: 3600, amplitude: 0.5),
          (start: 5000, end: 5500, amplitude: 0.5),
        ],
        sampleRate: 1000,
      );

      final result = computeAutoAlignedSentenceBoundaries(
        sentences: [
          sent(0, 2400, startWord: 0, endWord: 0),
          sent(5500, 5500, startWord: 1, endWord: 1),
        ],
        words: [word(0, 2400), word(5500, 5500)],
        audioData: decoded,
      );

      expect(result[0].endTime, closeTo(2.9, 1e-6));
      expect(result[1].startTime, closeTo(5.0, 1e-6));
    });

    test('R3 终检：第一级位移后 gap<minGap 时两侧都回原', () {
      // 自定义策略：对句对 [0.25, 0.75] 返回一个宽静音 [0.4, 0.6]，
      // padding=100ms 后 end=0.5 / start=0.5，gap=0 触发 pair-silence-gap-rejected
      // → 两侧回到 0.25 / 0.75；随后 fallback 以原值为起点分配 150ms，
      // 但我们让 words 紧贴原边界，验证 R2 不会干预。
      final decoded = _buildAudio(
        sampleCount: 1000,
        segments: const [(start: 0, end: 1000, amplitude: 0.2)],
        sampleRate: 1000,
      );
      final strategy = _MockStrategy(
        silenceIntervalsByRange: {
          _RangeKey(0.25, 0.75): [
            const SilenceInterval(startTime: 0.4, endTime: 0.6),
          ],
        },
      );

      final result = computeAutoAlignedSentenceBoundaries(
        sentences: [
          sent(0, 250, startWord: 0, endWord: 0),
          sent(750, 1000, startWord: 1, endWord: 1),
        ],
        words: [word(0, 250), word(750, 1000)],
        audioData: decoded,
        strategy: strategy,
      );

      // 第一级 gap 被 reject 后落入 fallback：gap=500ms, slack=450ms, 各侧吃满 150ms。
      expect(result[0].endTime, closeTo(0.4, 1e-6));
      expect(result[1].startTime, closeTo(0.6, 1e-6));
    });

    test('R2 词边界保护：静音把边界推到词外部时回退原值', () {
      // S0 [0, 560]ms，word0=[500, 560]；S1 [600, 900]ms，word1=[600, 630]。
      // 人为让 strategy 返回静音 [0.56, 0.60] 覆盖候选中段，padding=100ms
      // 会把 S0.end 推到 0.46（落到 word0.endTime=0.56 之前 → R2 回退）。
      final decoded = _buildAudio(
        sampleCount: 900,
        segments: const [(start: 0, end: 900, amplitude: 0.3)],
        sampleRate: 1000,
      );
      final strategy = _MockStrategy(
        silenceIntervalsByRange: {
          _RangeKey(0.56, 0.60): [
            const SilenceInterval(startTime: 0.56, endTime: 0.60),
          ],
        },
      );

      final result = computeAutoAlignedSentenceBoundaries(
        sentences: [
          sent(0, 560, startWord: 0, endWord: 0),
          sent(600, 900, startWord: 1, endWord: 1),
        ],
        words: [word(500, 560), word(600, 630)],
        audioData: decoded,
        strategy: strategy,
      );

      // 第一级候选=[0.56, 0.60]，longestSilence=[0.56, 0.60]。
      // nextEnd = 0.56 + 0.1 = 0.66（相对 original 0.56 偏移 +100ms，在 maxShift 内）
      // nextStart = 0.60 - 0.1 = 0.50（相对 original 0.60 偏移 -100ms）
      // gap = 0.50 - 0.66 = -0.16 < minGap=0.05 → 整对回退到原值。
      // fallback：gap=0.04 < minGap=0.05 → 返回 null。
      // 最终保持原值。
      expect(result[0].endTime, closeTo(0.56, 1e-6));
      expect(result[1].startTime, closeTo(0.60, 1e-6));
    });

    test('原边界落在静音内时该侧不参与 150ms 兜底，只动另一侧', () {
      // Mock：全区间的 silenceIntervals 包含 [0.25, 0.35]，但 longestSilence 返回 null
      // （让第一级失效，fallback 接管）。S0.end=0.30 落在 [0.25, 0.35] 内 → canMoveEnd=false。
      final decoded = _buildAudio(
        sampleCount: 1000,
        segments: const [(start: 0, end: 1000, amplitude: 0.2)],
        sampleRate: 1000,
      );
      final strategy = _MockStrategy(
        defaultIntervals: const [
          SilenceInterval(startTime: 0.25, endTime: 0.35),
        ],
        // longestSilence 恒为 null
        longestSilenceOverride: () => null,
      );

      final result = computeAutoAlignedSentenceBoundaries(
        sentences: [
          sent(0, 300, startWord: 0, endWord: 0),
          sent(700, 1000, startWord: 1, endWord: 1),
        ],
        words: [word(0, 300), word(700, 1000)],
        audioData: decoded,
        strategy: strategy,
      );

      // gap=400ms, slack=350ms, canMoveEnd=false (在 silence [0.25, 0.35] 里)
      // canMoveStart=true → endShift=0, startShift=min(150ms, slack)=150ms。
      expect(result[0].endTime, closeTo(0.3, 1e-6));
      expect(result[1].startTime, closeTo(0.55, 1e-6));
    });

    test('动态阈值：在低能量但有明显静音的候选中仍能检出静音', () {
      // 响声幅度 0.02（低），静音幅度 0.0。固定阈值 -35dB 会把 0.02 (~-34dB) 判为响，
      // 动态阈值 = min(noiseFloor+10, -35)：noiseFloor ≈ -inf（真静音帧），
      // threshold=-inf，仅 rms=0 的帧会被判静。
      final decoded = _buildAudio(
        sampleCount: 1000,
        segments: const [
          (start: 0, end: 300, amplitude: 0.02),
          (start: 500, end: 1000, amplitude: 0.02),
        ],
        sampleRate: 1000,
      );

      const strategy = FixedThresholdSilenceStrategy();
      final silence = strategy.detectLongestSilence(
        decoded,
        0,
        1.0,
        defaultAutoAlignConfig,
      );

      expect(silence, isNotNull);
      expect(silence!.startTime, closeTo(0.3, 0.02));
      expect(silence.endTime, closeTo(0.5, 0.02));
    });
  });
}

/// 区间 key 用近似匹配，容忍浮点差。
class _RangeKey {
  final double start;
  final double end;
  const _RangeKey(this.start, this.end);

  @override
  bool operator ==(Object other) =>
      other is _RangeKey &&
      (other.start - start).abs() < 1e-6 &&
      (other.end - end).abs() < 1e-6;

  @override
  int get hashCode => (start * 1e6).round() ^ (end * 1e6).round();
}

/// 可控 SilenceDetectionStrategy，用于覆盖算法分支。
class _MockStrategy implements SilenceDetectionStrategy {
  final Map<_RangeKey, List<SilenceInterval>> silenceIntervalsByRange;
  final List<SilenceInterval> defaultIntervals;
  final SilenceInterval? Function()? longestSilenceOverride;

  _MockStrategy({
    this.silenceIntervalsByRange = const {},
    this.defaultIntervals = const [],
    this.longestSilenceOverride,
  });

  @override
  List<SilenceInterval> detectSilenceIntervals(
    DecodedAudioData audioData,
    double candidateStart,
    double candidateEnd,
    SilenceDetectionConfig config,
  ) {
    final key = _RangeKey(candidateStart, candidateEnd);
    return silenceIntervalsByRange[key] ?? defaultIntervals;
  }

  @override
  SilenceInterval? detectLongestSilence(
    DecodedAudioData audioData,
    double candidateStart,
    double candidateEnd,
    SilenceDetectionConfig config,
  ) {
    if (longestSilenceOverride != null) {
      return longestSilenceOverride!();
    }
    final ranges = detectSilenceIntervals(
      audioData,
      candidateStart,
      candidateEnd,
      config,
    );
    SilenceInterval? best;
    var bestDuration = 0.0;
    for (final r in ranges) {
      final clampedStart = candidateStart > r.startTime
          ? candidateStart
          : r.startTime;
      final clampedEnd = candidateEnd < r.endTime ? candidateEnd : r.endTime;
      final dur = clampedEnd - clampedStart;
      if (dur > bestDuration) {
        bestDuration = dur;
        best = SilenceInterval(startTime: clampedStart, endTime: clampedEnd);
      }
    }
    return best;
  }
}
