import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/providers/tts/tts_controller_provider.dart';
import 'package:loop_back/services/tts/tts_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('effectiveTtsEngine 生效门控', () {
    test('选平台 → 始终平台', () {
      expect(
        effectiveTtsEngine(
          TtsEngineKind.platform,
          kokoroReady: false,
          piperReady: false,
        ),
        TtsEngineKind.platform,
      );
      expect(
        effectiveTtsEngine(
          TtsEngineKind.platform,
          kokoroReady: true,
          piperReady: true,
        ),
        TtsEngineKind.platform,
      );
    });

    test('选 Kokoro 但未就绪 → 仍使用 Kokoro，不回退平台', () {
      expect(
        effectiveTtsEngine(
          TtsEngineKind.kokoro,
          kokoroReady: false,
          piperReady: true,
        ),
        TtsEngineKind.kokoro,
      );
    });

    test('选 Kokoro 且已就绪 → Kokoro', () {
      expect(
        effectiveTtsEngine(
          TtsEngineKind.kokoro,
          kokoroReady: true,
          piperReady: false,
        ),
        TtsEngineKind.kokoro,
      );
    });

    test('选 Piper 但未就绪 → 仍使用 Piper，不回退平台', () {
      expect(
        effectiveTtsEngine(
          TtsEngineKind.piper,
          kokoroReady: true,
          piperReady: false,
        ),
        TtsEngineKind.piper,
      );
    });

    test('选 Piper 且已就绪 → Piper', () {
      expect(
        effectiveTtsEngine(
          TtsEngineKind.piper,
          kokoroReady: false,
          piperReady: true,
        ),
        TtsEngineKind.piper,
      );
    });
  });
}
