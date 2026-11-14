import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/services/asr/asr_model_catalog.dart'
    show AsrPublicResourceLayout;
import 'package:loop_back/services/tts/piper_model_catalog.dart';
import 'package:loop_back/services/tts/tts_engine.dart';

void main() {
  test('目录包含 7 个 Piper 音色，男女与口音分布符合决策', () {
    expect(piperVoices, hasLength(7));
    expect(piperVoicesByAccent(TtsAccent.us), hasLength(5));
    expect(piperVoicesByAccent(TtsAccent.uk), hasLength(2));
    expect(piperVoices.map((voice) => voice.id).toSet(), hasLength(7));
    expect(
      piperVoices.where((voice) => voice.accent == TtsAccent.us && voice.isFemale),
      hasLength(2),
    );
    expect(
      piperVoices.where((voice) => voice.accent == TtsAccent.us && !voice.isFemale),
      hasLength(3),
    );
    for (final voice in piperVoices) {
      expect(voice.license, isNotEmpty);
      expect(voice.displayName, isNotEmpty);
      expect(voice.resource.files, isNotEmpty);
      // 全部走 HF 逐文件下载，不再依赖自建 GitHub 发布资产。
      expect(voice.resource.layout, AsrPublicResourceLayout.huggingFaceResolve);
      expect(voice.resource.dependencies, ['espeak-ng-data']);
    }
    expect(piperPublicResourceCatalog.length, 8); // 7 音色 + 共享 espeak
  });

  test('许可口径：只收 public domain，唯一例外是 CC-BY-SA 英音男声', () {
    final nonPublicDomain = piperVoices
        .where((voice) => voice.license != 'public domain')
        .map((voice) => '${voice.id} -> ${voice.license}')
        .toList();
    expect(nonPublicDomain, [
      'en_GB-northern_english_male-medium -> CC BY-SA 4.0',
    ]);
  });

  test('默认音色：美音 kristin、英音 cori-high，且都自带对应口音', () {
    expect(piperDefaultVoiceUs, 'en_US-kristin-medium');
    expect(piperDefaultVoiceUk, 'en_GB-cori-high');
    expect(piperDefaultVoice(TtsAccent.us).id, piperDefaultVoiceUs);
    expect(piperDefaultVoice(TtsAccent.uk).id, piperDefaultVoiceUk);
    expect(piperVoiceById(piperDefaultVoiceUs)!.accent, TtsAccent.us);
    expect(piperVoiceById(piperDefaultVoiceUk)!.accent, TtsAccent.uk);
  });

  test('已移除音色 ID 用于启动清理，且不再出现在目录中', () {
    // 历史许可移除的两个 + 本轮许可收紧下线的六个。
    expect(removedPiperVoiceIds, [
      'en_US-lessac-medium',
      'en_GB-alan-medium',
      'en_US-amy-medium',
      'en_US-ryan-medium',
      'en_US-joe-medium',
      'en_US-hfc_female-medium',
      'en_GB-cori-medium',
      'en_GB-alba-medium',
    ]);
    for (final id in removedPiperVoiceIds) {
      expect(piperVoiceById(id), isNull);
    }
  });

  test('未知音色查询返回 null', () {
    expect(piperVoiceById('not_a_voice'), isNull);
  });
}
