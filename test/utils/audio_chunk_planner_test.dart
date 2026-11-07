/// 长音频分块规划的行为测试：块边界、静音切点、无声判定与边界局部对齐。
library;

import 'dart:typed_data';

import 'package:echo_loop/services/asr/offline_asr_engine.dart' show AsrSegment;
import 'package:echo_loop/utils/audio_chunk_planner.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造 16 kHz 单声道 16 bit PCM；[silent] 内的绝对时间写成 0 振幅。
Uint8List _pcm({
  required Duration duration,
  List<(Duration, Duration)> silent = const [],
  int amplitude = 8000,
}) {
  final samples = duration.inMicroseconds * 16000 ~/ 1000000;
  final bytes = Uint8List(samples * 2);
  for (var i = 0; i < samples; i++) {
    final t = Duration(microseconds: i * 1000000 ~/ 16000);
    final muted = silent.any((range) => t >= range.$1 && t < range.$2);
    final value = muted ? 0 : (i.isEven ? amplitude : -amplitude);
    bytes[i * 2] = value & 0xff;
    bytes[i * 2 + 1] = (value >> 8) & 0xff;
  }
  return bytes;
}

/// 带 44 字节标准 WAV 头的载荷，验证头部会被跳过。
Uint8List _wav(Uint8List pcm) {
  final header = Uint8List(44);
  header.setAll(0, const [0x52, 0x49, 0x46, 0x46]);
  return Uint8List.fromList([...header, ...pcm]);
}

AsrSegment _segment(String text, int startMs, int endMs) => AsrSegment(
  text: text,
  start: Duration(milliseconds: startMs),
  end: Duration(milliseconds: endMs),
);

void main() {
  group('planAudioChunks', () {
    test('探测不到静音时按目标时长硬切，块间留重叠且都不超过上限', () async {
      final chunks = await planAudioChunks(
        totalDuration: const Duration(minutes: 4),
        probe: (_, _) async => null,
      );

      expect(chunks, hasLength(3));
      expect(chunks.first.start, Duration.zero);
      expect(chunks.first.end, const Duration(seconds: 100));
      expect(chunks.first.hardCut, isTrue);
      // 硬切给下一块留 1 秒重叠，跨块单词两边都能识别到。
      expect(chunks[1].start, const Duration(seconds: 99));
      expect(chunks.last.end, const Duration(minutes: 4));
      for (final chunk in chunks) {
        expect(chunk.duration, lessThanOrEqualTo(audioChunkMaxDuration));
        expect(chunk.duration, greaterThan(Duration.zero));
      }
    });

    test('探测到静音时在静音处切开，不加重叠', () async {
      final chunks = await planAudioChunks(
        totalDuration: const Duration(minutes: 4),
        probe: (from, to) async => from + const Duration(seconds: 10),
      );

      expect(chunks.first.hardCut, isFalse);
      expect(chunks.first.end, const Duration(seconds: 90));
      expect(chunks[1].start, chunks.first.end);
    });

    test('探测结果超出搜索范围时按硬切处理，不做不可解释的切点', () async {
      final chunks = await planAudioChunks(
        totalDuration: const Duration(minutes: 4),
        probe: (_, _) async => const Duration(seconds: 5),
      );

      expect(chunks.first.hardCut, isTrue);
      expect(chunks.first.end, const Duration(seconds: 100));
    });

    test('短材料只有一块，不切分', () async {
      final chunks = await planAudioChunks(
        totalDuration: const Duration(seconds: 60),
        probe: (_, _) async => fail('短材料不需要探测切点'),
      );

      expect(chunks, hasLength(1));
      expect(chunks.single.start, Duration.zero);
      expect(chunks.single.end, const Duration(seconds: 60));
    });
  });

  group('quietestCutInPcm', () {
    test('在探测窗口内选出静音处，返回静音窗口中心', () async {
      final pcm = _pcm(
        duration: const Duration(seconds: 40),
        silent: const [
          (Duration(seconds: 18), Duration(seconds: 21)),
        ],
      );

      final cut = quietestCutInPcm(
        wavBytes: _wav(pcm),
        windowStart: const Duration(seconds: 80),
      );

      expect(cut, isNotNull);
      // 返回值是绝对时刻：窗口起点 80s 加上静音区内约 18s。
      expect(cut!.inMilliseconds, inInclusiveRange(98000, 101000));
      expect(cut, lessThan(const Duration(seconds: 100)));
    });

    test('整段都有声时不给切点，交由硬切处理', () async {
      final pcm = _pcm(duration: const Duration(seconds: 40));

      expect(quietestCutInPcm(wavBytes: pcm, windowStart: Duration.zero), isNull);
    });

    test('载荷不足一个评估窗口时不给切点', () {
      final pcm = _pcm(duration: const Duration(milliseconds: 100));

      expect(quietestCutInPcm(wavBytes: pcm, windowStart: Duration.zero), isNull);
    });
  });

  group('isSilentPcm', () {
    test('全零振幅的块确认为无声', () {
      expect(isSilentPcm(_pcm(duration: const Duration(seconds: 5))), isFalse);
      expect(
        isSilentPcm(
          _pcm(
            duration: const Duration(seconds: 5),
            silent: const [
              (Duration.zero, Duration(seconds: 5)),
            ],
          ),
        ),
        isTrue,
      );
    });

    test('空音频不当作无声，避免掩盖解码问题', () {
      expect(isSilentPcm(Uint8List(0)), isFalse);
    });
  });

  group('trimChunkOverlap', () {
    const boundary = Duration(seconds: 100);

    test('重叠区里重复识别的整句只保留一份', () {
      final next = [
        _segment('Thank you.', 0, 900),
        _segment('Next topic.', 3000, 5000),
      ];

      final trimmed = trimChunkOverlap(
        previousTail: [_segment('Thank you.', 98400, 99900)],
        next: next,
        boundary: boundary,
      );

      expect(trimmed.map((s) => s.text), ['Next topic.']);
    });

    test('材料里远处真实重复的句子保留', () {
      final next = [
        _segment('Thank you.', 0, 900),
        _segment('Thank you.', 20000, 20900),
      ];

      final trimmed = trimChunkOverlap(
        previousTail: [_segment('Thank you.', 98400, 99900)],
        next: next,
        boundary: boundary,
      );

      // 只去掉重叠区内那一句；后面的真实重复属于新材料内容。
      expect(trimmed.map((s) => s.text), ['Thank you.']);
      expect(trimmed.single.start, const Duration(seconds: 20));
    });

    test('跨在切点上的句子保留，不丢被切开的单词', () {
      final next = [
        _segment('crossword continues.', 0, 1800),
        _segment('Another sentence.', 4000, 6000),
      ];

      final trimmed = trimChunkOverlap(
        previousTail: [_segment('We keep the', 98000, 99500)],
        next: next,
        boundary: boundary,
      );

      expect(trimmed, hasLength(2));
    });

    test('文本对不上时一句都不删', () {
      final next = [_segment('Different words.', 0, 500)];

      final trimmed = trimChunkOverlap(
        previousTail: [_segment('Nothing in common.', 98000, 99500)],
        next: next,
        boundary: boundary,
      );

      expect(trimmed, hasLength(1));
    });
  });
}
