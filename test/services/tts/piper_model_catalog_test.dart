import 'package:flutter_test/flutter_test.dart';
import 'package:echo_loop/services/tts/piper_model_catalog.dart';
import 'package:echo_loop/services/tts/tts_engine.dart';

void main() {
  test('目录包含 7 个 Piper 音色，且许可与资源完整', () {
    expect(piperVoices, hasLength(7));
    expect(piperVoicesByAccent(TtsAccent.us), hasLength(5));
    expect(piperVoicesByAccent(TtsAccent.uk), hasLength(2));
    expect(piperVoices.map((voice) => voice.id).toSet(), hasLength(7));
    for (final voice in piperVoices) {
      expect(voice.license, isNotEmpty);
      expect(voice.displayName, isNotEmpty);
      expect(voice.resource.files, isNotEmpty);
    }
    expect(piperPublicResourceCatalog.length, 8); // 7 音色 + 共享 espeak
  });

  test('默认音色按口音匹配，英音默认为 cori', () {
    expect(piperDefaultVoice(TtsAccent.us).id, piperDefaultVoiceUs);
    expect(piperDefaultVoiceUk, 'en_GB-cori-medium');
    expect(piperDefaultVoice(TtsAccent.uk).id, piperDefaultVoiceUk);
  });

  test('已移除音色 ID 用于启动清理，且不再出现在目录中', () {
    expect(removedPiperVoiceIds, [
      'en_US-lessac-medium',
      'en_GB-alan-medium',
    ]);
    for (final id in removedPiperVoiceIds) {
      expect(piperVoiceById(id), isNull);
    }
  });

  test('未知音色查询返回 null', () {
    expect(piperVoiceById('not_a_voice'), isNull);
  });
}
