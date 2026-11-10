import 'package:flutter_test/flutter_test.dart';
import 'package:echo_loop/services/tts/piper_model_catalog.dart';
import 'package:echo_loop/services/tts/tts_engine.dart';

void main() {
  test('目录包含 9 个 Piper 音色，且许可与再分发标记完整', () {
    expect(piperVoices, hasLength(9));
    expect(piperVoicesByAccent(TtsAccent.us), hasLength(6));
    expect(piperVoicesByAccent(TtsAccent.uk), hasLength(3));
    expect(piperVoices.map((voice) => voice.id).toSet(), hasLength(9));
    for (final voice in piperVoices) {
      expect(voice.license, isNotEmpty);
      expect(voice.displayName, isNotEmpty);
    }
  });

  test('7 个许可允许再分发的音色有公开资源，2 个禁止再分发的音色无资源', () {
    final downloadable = piperVoices.where((v) => v.redistributable);
    expect(downloadable, hasLength(7));
    expect(
      piperVoices.where((v) => !v.redistributable).map((v) => v.id).toSet(),
      {'en_US-lessac-medium', 'en_GB-alan-medium'},
    );
    for (final voice in downloadable) {
      expect(voice.resource, isNotNull);
      expect(voice.resource!.files, isNotEmpty);
    }
    expect(piperPublicResourceCatalog.length, 8); // 7 音色 + 共享 espeak
  });

  test('默认音色按口音匹配，英音默认改为可再分发的 cori', () {
    expect(piperDefaultVoice(TtsAccent.us).id, piperDefaultVoiceUs);
    expect(piperDefaultVoiceUk, 'en_GB-cori-medium');
    expect(piperDefaultVoice(TtsAccent.uk).id, piperDefaultVoiceUk);
    expect(piperDefaultVoice(TtsAccent.uk).redistributable, isTrue);
  });

  test('未知音色查询返回 null', () {
    expect(piperVoiceById('not_a_voice'), isNull);
  });
}
