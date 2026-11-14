import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/services/tts/kokoro_voices.dart';
import 'package:loop_back/services/tts/tts_engine.dart';

void main() {
  group('kokoroVoices 目录', () {
    test('共 28 个英语发音人，sid 连续覆盖 0..27 且唯一', () {
      expect(kokoroVoices.length, 28);
      final sids = kokoroVoices.map((v) => v.sid).toList()..sort();
      expect(sids, List.generate(28, (i) => i));
    });

    test('id 唯一', () {
      final ids = kokoroVoices.map((v) => v.id).toSet();
      expect(ids.length, 28);
    });

    test('只收录英语音色：美音 20、英音 8，无其他语言', () {
      expect(voicesForAccent(TtsAccent.us).length, 20);
      expect(voicesForAccent(TtsAccent.uk).length, 8);
      // 目录里每个 id 都以 a/b 开头（en-US / en-GB），不含 es/fr/hi/it/ja/pt/zh 音色。
      expect(
        kokoroVoices.every((v) => v.id.startsWith('a') || v.id.startsWith('b')),
        isTrue,
      );
      expect(voiceById('zf_xiaoxiao'), isNull);
      expect(voiceById('jf_alpha'), isNull);
    });

    test('关键 sid 与 sherpa-onnx v1.0 speaker ID 表一致', () {
      expect(voiceById('af_alloy')!.sid, 0);
      expect(voiceById('af_heart')!.sid, 3);
      expect(voiceById('af_bella')!.sid, 2);
      expect(voiceById('af_nicole')!.sid, 6);
      expect(voiceById('af_sarah')!.sid, 9);
      expect(voiceById('af_sky')!.sid, 10);
      expect(voiceById('am_adam')!.sid, 11);
      expect(voiceById('am_michael')!.sid, 16);
      expect(voiceById('am_santa')!.sid, 19);
      expect(voiceById('bf_alice')!.sid, 20);
      expect(voiceById('bf_emma')!.sid, 21);
      expect(voiceById('bf_isabella')!.sid, 22);
      expect(voiceById('bm_george')!.sid, 26);
      expect(voiceById('bm_lewis')!.sid, 27);
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
      // 'af_heart'（v1.0 旗舰女声）。
      expect(voiceById('af_heart')!.isFemale, isTrue);
    });
  });

  group('voiceById', () {
    test('已知 id 往返', () {
      final v = voiceById('bf_emma');
      expect(v, isNotNull);
      expect(v!.id, 'bf_emma');
      expect(v.sid, 21);
      expect(v.displayName, 'Emma');
    });

    test('v0.19 的 af 已退役，返回 null', () {
      expect(voiceById('af'), isNull);
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
      expect(sidForVoiceId('am_michael', fallbackAccent: TtsAccent.us), 16);
    });

    test('null → 回退到该口音默认音色 sid', () {
      expect(sidForVoiceId(null, fallbackAccent: TtsAccent.us), 9); // af_sarah
      expect(sidForVoiceId(null, fallbackAccent: TtsAccent.uk), 21); // bf_emma
    });

    test('未知 voiceId → 回退默认', () {
      expect(sidForVoiceId('ghost', fallbackAccent: TtsAccent.uk), 21);
      // 存量偏好里的 v0.19 'af' 已退役，回退到该口音默认音色。
      expect(sidForVoiceId('af', fallbackAccent: TtsAccent.us), 9);
    });
  });
}
