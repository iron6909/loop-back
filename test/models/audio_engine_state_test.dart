import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/audio_engine_state.dart';

void main() {
  group('AudioEngineState', () {
    group('默认值正确性', () {
      test('所有默认值符合预期', () {
        const state = AudioEngineState();

        expect(state.clipStart, Duration.zero);
        expect(state.isClipActive, isFalse);
        expect(state.totalDuration, isNull);
        expect(state.isLoading, isFalse);
        expect(state.sessionId, 0);
        expect(state.currentAudioId, isNull);
        expect(state.errorMessage, isNull);
      });
    });

    group('copyWith', () {
      test('部分字段覆盖', () {
        const state = AudioEngineState();
        final copied = state.copyWith(
          clipStart: const Duration(seconds: 30),
          isClipActive: true,
          isLoading: true,
          sessionId: 5,
        );

        expect(copied.clipStart, const Duration(seconds: 30));
        expect(copied.isClipActive, isTrue);
        expect(copied.isLoading, isTrue);
        expect(copied.sessionId, 5);
        // 未修改字段保持原值
        expect(copied.totalDuration, isNull);
        expect(copied.currentAudioId, isNull);
        expect(copied.errorMessage, isNull);
      });

      test('设置可选字段', () {
        const state = AudioEngineState();
        final copied = state.copyWith(
          totalDuration: const Duration(minutes: 5),
          currentAudioId: 'audio-1',
          errorMessage: '加载失败',
        );

        expect(copied.totalDuration, const Duration(minutes: 5));
        expect(copied.currentAudioId, 'audio-1');
        expect(copied.errorMessage, '加载失败');
      });

      test('不传参数时保持原值', () {
        final state = const AudioEngineState(
          clipStart: Duration(seconds: 10),
          isClipActive: true,
          sessionId: 3,
        );
        final copied = state.copyWith();

        expect(copied.clipStart, const Duration(seconds: 10));
        expect(copied.isClipActive, isTrue);
        expect(copied.sessionId, 3);
      });
    });
  });
}
