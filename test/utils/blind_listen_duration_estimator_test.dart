import 'package:loop_back/models/sentence.dart';
import 'package:loop_back/utils/blind_listen_duration_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

Sentence _s(int i, int startSec, int endSec) => Sentence(
  index: i,
  text: 'sentence $i',
  startTime: Duration(seconds: startSec),
  endTime: Duration(seconds: endSec),
);

void main() {
  // 三句字幕：0-2s, 3-5s, 7-9s
  // 字幕有效时长 = 6s（2s × 3），音频总时长 30s（含 24s 静音）
  final sentences = [_s(0, 0, 2), _s(1, 3, 5), _s(2, 7, 9)];
  const audioDur = Duration(seconds: 30);

  group('estimateBlindListenSessionDuration', () {
    test('跳过开启 → 返回字幕有效时长（句时长之和），剔除静音', () {
      final r = estimateBlindListenSessionDuration(
        sentences: sentences,
        fullAudioDuration: audioDur,
        skipSilenceEnabled: true,
      );
      expect(r, const Duration(seconds: 6));
    });

    test('跳过关闭 → 返回完整音频时长', () {
      final r = estimateBlindListenSessionDuration(
        sentences: sentences,
        fullAudioDuration: audioDur,
        skipSilenceEnabled: false,
      );
      expect(r, audioDur);
    });

    test('跳过开启但字幕为空 → 回退到音频总时长', () {
      final r = estimateBlindListenSessionDuration(
        sentences: const [],
        fullAudioDuration: audioDur,
        skipSilenceEnabled: true,
      );
      expect(r, audioDur);
    });

    test('跳过开启且字幕和音频都为空 → null', () {
      final r = estimateBlindListenSessionDuration(
        sentences: const [],
        fullAudioDuration: null,
        skipSilenceEnabled: true,
      );
      expect(r, isNull);
    });

    test('跳过关闭但音频时长缺失 → null', () {
      final r = estimateBlindListenSessionDuration(
        sentences: sentences,
        fullAudioDuration: null,
        skipSilenceEnabled: false,
      );
      expect(r, isNull);
    });
  });
}
