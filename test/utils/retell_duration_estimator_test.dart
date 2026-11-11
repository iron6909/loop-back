import 'package:loop_back/models/sentence.dart';
import 'package:loop_back/utils/retell_duration_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

Sentence _s(int i, int startSec, int endSec) => Sentence(
  index: i,
  text: 'sentence $i',
  startTime: Duration(seconds: startSec),
  endTime: Duration(seconds: endSec),
);

void main() {
  // 三句字幕：0-2s, 3-5s, 7-9s（句间空白 1s/2s）
  // 整体 wall-clock 9s（last.end - first.start），有效说话 6s（2s × 3）
  final sentences = [_s(0, 0, 2), _s(1, 3, 5), _s(2, 7, 9)];

  group('estimateRetellSessionDuration', () {
    test('空字幕返回 0', () {
      final r = estimateRetellSessionDuration(
        sentences: const [],
        targetSeconds: -1,
        pauseMultiplier: -1,
      );
      expect(r, Duration.zero);
    });

    test(
      '不分段 + smart：paragraphDur=9s, pause=clamp(2+9×2,3..60)=20s → total=29s',
      () {
        final r = estimateRetellSessionDuration(
          sentences: sentences,
          targetSeconds: -1,
          pauseMultiplier: -1,
        );
        expect(r, const Duration(seconds: 29));
      },
    );

    test(
      '逐句 + multiplier 1.0：每段 2s, pause=clamp(2×1,≥3)=3s → 3 × (2+3) = 15s',
      () {
        final r = estimateRetellSessionDuration(
          sentences: sentences,
          targetSeconds: 0,
          pauseMultiplier: 1.0,
        );
        expect(r, const Duration(seconds: 15));
      },
    );

    test('repeatCount=2 时整体翻倍', () {
      final r = estimateRetellSessionDuration(
        sentences: sentences,
        targetSeconds: -1,
        pauseMultiplier: -1,
        repeatCount: 2,
      );
      expect(r, const Duration(seconds: 58));
    });

    test('multiplier 模式段落较长时不被 clamp 抬到 3s', () {
      // 单段 wall-clock = 9s，multiplier=2 → pause=18s（不触发下限）
      // total = 9 + 18 = 27s
      final r = estimateRetellSessionDuration(
        sentences: sentences,
        targetSeconds: -1,
        pauseMultiplier: 2.0,
      );
      expect(r, const Duration(seconds: 27));
    });
  });
}
