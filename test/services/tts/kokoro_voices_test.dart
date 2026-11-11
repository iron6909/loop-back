import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/services/tts/kokoro_voices.dart';
import 'package:loop_back/services/tts/tts_engine.dart';

void main() {
  group('kokoroVoices 目录', () {
    test('共 11 个发音人，sid 连续覆盖 0..10 且唯一', () {
      expect(kokoroVoices.length, 11);
      final sids = kokoroVoices.map((v) => v.sid).toList()..sort();
      expect(sids, List.generate(11, (i) => i));
    });

    test('id 唯一', () {
      final ids = kokoroVoices.map((v) => v.id).toSet();
      expect(ids.length, 11);
    });

    test('口音分组：美音 7 个、英音 4 个', () {
      expect(voicesForAccent(TtsAccent.us).length, 7);
      expect(voicesForAccent(TtsAccent.uk).length, 4);
    });

    test('口音由 id 前缀推导：a*=美音 b*=英音', () {
      expect(voiceById('af_sarah')!.accent, TtsAccent.us);
      expect(voiceById('am_adam')!.accent, TtsAccent.us);
      expect(voiceById('bf_emma')!.accent, TtsAccent.uk);
      expect(voiceById('bm_lewis')!.accent, TtsAccent.uk);
    });

    test('性别由第二字符推导：*f_=女声 *m_=男声', () {
      expect(voiceById('af_sarah')!.isFemale, isTrue);
      expect(voiceById('am_adam')!.isFemale, isFalse);
      expect(voiceById('bf_emma')!.isFemale, isTrue);
      expect(voiceById('bm_george')!.isFemale, isFalse);
      // 'af'（无下划线）默认女声。
      expect(voiceById('af')!.isFemale, isTrue);
    });
  });

  group('voiceById', () {
    test('已知 id 往返', () {
      final v = voiceById('bf_emma');
      expect(v, isNotNull);
      expect(v!.id, 'bf_emma');
      expect(v.sid, 7);
      expect(v.displayName, 'Emma');
    });

    test('未知 id 返回 null', () {
      expect(voiceById('not_a_voice'), isNull);
    });
  });

  group('defaultVoice', () {
    test('美音默认 af_sarah，且属于美音', () {
      final v = defaultVoice(TtsAccent.us);
      expect(v.id, kokoroDefaultVoiceUs);
      expect(v.id, 'af_sarah');
      expect(v.accent, TtsAccent.us);
    });

    test('英音默认 bf_emma，且属于英音', () {
      final v = defaultVoice(TtsAccent.uk);
      expect(v.id, kokoroDefaultVoiceUk);
      expect(v.id, 'bf_emma');
      expect(v.accent, TtsAccent.uk);
    });
  });

  group('sidForVoiceId', () {
    test('已知 voiceId → 对应 sid', () {
      expect(sidForVoiceId('am_michael', fallbackAccent: TtsAccent.us), 6);
    });

    test('null → 回退到该口音默认音色 sid', () {
      expect(sidForVoiceId(null, fallbackAccent: TtsAccent.us), 3); // af_sarah
      expect(sidForVoiceId(null, fallbackAccent: TtsAccent.uk), 7); // bf_emma
    });

    test('未知 voiceId → 回退默认', () {
      expect(sidForVoiceId('ghost', fallbackAccent: TtsAccent.uk), 7);
    });
  });
}
