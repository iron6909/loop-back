import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/playback_settings.dart';
import 'package:loop_back/models/repeat_count_options.dart';

void main() {
  group('PlaybackSettings', () {
    group('默认值正确性', () {
      test('循环次数选项顺序包含新增档位和无限', () {
        expect(kRepeatCountOptions, const [
          1,
          2,
          3,
          4,
          5,
          6,
          7,
          8,
          9,
          10,
          20,
          30,
          40,
          50,
          0,
        ]);
      });

      test('Free Player 支持的速度档位符合预期', () {
        expect(kFreePlayerPlaybackSpeeds, const [
          0.4,
          0.5,
          0.6,
          0.7,
          0.8,
          0.9,
          1.0,
          1.1,
          1.2,
          1.3,
          1.4,
          1.5,
          2.0,
        ]);
      });

      test('所有默认值符合预期', () {
        const settings = PlaybackSettings();

        expect(settings.loopWhole, isFalse);
        expect(settings.wholeLoopCount, 3);
        expect(settings.wholeInterval, const Duration(seconds: 3));
        expect(settings.loopSentence, isFalse);
        expect(settings.sentenceLoopCount, 3);
        expect(settings.sentenceInterval, const Duration(seconds: 2));
        expect(settings.playbackSpeed, 1.0);
        expect(settings.singleSentenceMode, isFalse);
        expect(settings.showTranscript, isTrue);
        expect(settings.isInfiniteWhole, isFalse);
        expect(settings.isInfiniteSentence, isFalse);
      });

      test('收藏 tab 默认循环语义符合预期', () {
        expect(kDefaultBookmarkPlaybackSettings.loopSentence, isTrue);
        expect(kDefaultBookmarkPlaybackSettings.sentenceLoopCount, 1);
        expect(
          kDefaultBookmarkPlaybackSettings.sentenceInterval,
          const Duration(seconds: 1),
        );
      });
    });

    group('toJson / fromJson 往返序列化', () {
      test('循环开关与循环参数往返保留', () {
        const settings = PlaybackSettings(
          loopWhole: true,
          loopSentence: false,
          playbackSpeed: 1.5,
        );
        final restored = PlaybackSettings.fromJson(settings.toJson());

        expect(restored.loopWhole, isTrue);
        expect(restored.loopSentence, isFalse);
      });

      test('toJson 同时包含循环开关和循环参数键', () {
        const settings = PlaybackSettings(loopWhole: true, loopSentence: true);
        final json = settings.toJson();

        expect(json['loopWhole'], isTrue);
        expect(json['loopSentence'], isTrue);
        expect(json.containsKey('wholeLoopCount'), isTrue);
        expect(json.containsKey('sentenceLoopCount'), isTrue);
        expect(json.containsKey('wholeInterval'), isTrue);
        expect(json.containsKey('sentenceInterval'), isTrue);
      });

      test('循环参数与其他偏好往返保留', () {
        const settings = PlaybackSettings(
          wholeLoopCount: 5,
          wholeInterval: Duration(seconds: 4),
          sentenceLoopCount: 2,
          sentenceInterval: Duration(seconds: 1),
          playbackSpeed: 1.5,
          singleSentenceMode: true,
          showTranscript: false,
        );
        final restored = PlaybackSettings.fromJson(settings.toJson());

        expect(restored.wholeLoopCount, settings.wholeLoopCount);
        expect(restored.wholeInterval, settings.wholeInterval);
        expect(restored.sentenceLoopCount, settings.sentenceLoopCount);
        expect(restored.sentenceInterval, settings.sentenceInterval);
        expect(restored.playbackSpeed, settings.playbackSpeed);
        expect(restored.singleSentenceMode, settings.singleSentenceMode);
        expect(restored.showTranscript, settings.showTranscript);
      });

      test('间隔以毫秒序列化', () {
        const settings = PlaybackSettings(
          wholeInterval: Duration(seconds: 5),
          sentenceInterval: Duration(seconds: 3),
        );
        final json = settings.toJson();
        expect(json['wholeInterval'], 5000);
        expect(json['sentenceInterval'], 3000);
      });

      test('循环次数 0（∞）作为参数往返保留', () {
        const settings = PlaybackSettings(
          wholeLoopCount: 0,
          sentenceLoopCount: 0,
        );
        final restored = PlaybackSettings.fromJson(settings.toJson());
        expect(restored.wholeLoopCount, 0);
        expect(restored.sentenceLoopCount, 0);
      });
    });

    group('旧字段兼容（缺失开关时默认关闭，仅迁移参数）', () {
      test('旧 repeatMode=one 仅迁移单句循环参数，开关默认关闭', () {
        final settings = PlaybackSettings.fromJson({
          'repeatMode': 'one',
          'loopCount': 5,
          'pauseInterval': 4000,
        });
        expect(settings.sentenceLoopCount, 5);
        expect(settings.sentenceInterval, const Duration(seconds: 4));
        expect(settings.loopSentence, isFalse);
        expect(settings.loopWhole, isFalse);
      });

      test('旧 repeatMode=all 不会开启整篇循环', () {
        final settings = PlaybackSettings.fromJson({'repeatMode': 'all'});
        expect(settings.loopWhole, isFalse);
        expect(settings.loopSentence, isFalse);
      });

      test('旧 repeatMode=off 两者皆关', () {
        final settings = PlaybackSettings.fromJson({'repeatMode': 'off'});
        expect(settings.loopWhole, isFalse);
        expect(settings.loopSentence, isFalse);
      });

      test('更旧 loopEnabled=true 不会开启循环', () {
        final settings = PlaybackSettings.fromJson({'loopEnabled': true});
        expect(settings.loopSentence, isFalse);
        expect(settings.loopWhole, isFalse);
      });

      test('更旧 loopAudioEnabled=true 不会开启循环', () {
        final settings = PlaybackSettings.fromJson({'loopAudioEnabled': true});
        expect(settings.loopWhole, isFalse);
        expect(settings.loopSentence, isFalse);
      });

      test('迁移时旧 loopCount 在新上限内保留', () {
        final settings = PlaybackSettings.fromJson({
          'repeatMode': 'one',
          'loopCount': 18,
        });
        expect(settings.sentenceLoopCount, 18);
      });

      test('仅含参数键的 JSON 被识别为新 schema，参数保留', () {
        final settings = PlaybackSettings.fromJson({
          'wholeLoopCount': 4,
          'sentenceLoopCount': 2,
        });
        expect(settings.wholeLoopCount, 4);
        expect(settings.sentenceLoopCount, 2);
        expect(settings.loopWhole, isFalse);
        expect(settings.loopSentence, isFalse);
      });
    });

    group('fromJson 范围校验', () {
      test('旧持久化速度若不在新档位中则吸附到最近新档位', () {
        final settings = PlaybackSettings.fromJson({'playbackSpeed': 1.75});
        expect(settings.playbackSpeed, 2.0);
      });

      test('新档位速度从 JSON 读取时保留原值', () {
        final settings = PlaybackSettings.fromJson({'playbackSpeed': 1.4});
        expect(settings.playbackSpeed, 1.4);
      });

      test('次数 = 0 解析为 0（∞ 语义）', () {
        final settings = PlaybackSettings.fromJson({'sentenceLoopCount': 0});
        expect(settings.sentenceLoopCount, 0);
      });

      test('次数 > 50 截断为 50，新增档位可读取', () {
        for (final count in [20, 30, 40, 50]) {
          expect(
            PlaybackSettings.fromJson({'wholeLoopCount': count}).wholeLoopCount,
            count,
          );
        }
        final settings = PlaybackSettings.fromJson({'wholeLoopCount': 100});
        expect(settings.wholeLoopCount, 50);
      });

      test('次数为负重置为默认 3', () {
        final settings = PlaybackSettings.fromJson({'sentenceLoopCount': -5});
        expect(settings.sentenceLoopCount, 3);
      });

      test('次数非 int 类型使用默认 3', () {
        final settings = PlaybackSettings.fromJson({'wholeLoopCount': 'abc'});
        expect(settings.wholeLoopCount, 3);
      });

      test('间隔负值截断为 0', () {
        final settings = PlaybackSettings.fromJson({'sentenceInterval': -1000});
        expect(settings.sentenceInterval, Duration.zero);
      });

      test('间隔 > 10 秒截断为 10 秒', () {
        final settings = PlaybackSettings.fromJson({'wholeInterval': 60000});
        expect(settings.wholeInterval, const Duration(seconds: 10));
      });
    });

    group('copyWith', () {
      test('部分字段覆盖', () {
        const settings = PlaybackSettings();
        final copied = settings.copyWith(
          loopSentence: true,
          playbackSpeed: 2.0,
        );

        expect(copied.loopSentence, isTrue);
        expect(copied.playbackSpeed, 2.0);
        // 未修改字段保持原值
        expect(copied.sentenceLoopCount, 3);
        expect(copied.loopWhole, isFalse);
        expect(copied.showTranscript, isTrue);
      });

      test('withBookmarkLoopDefaults 重置收藏循环并保留其他偏好', () {
        const settings = PlaybackSettings(
          loopWhole: true,
          wholeLoopCount: 9,
          playbackSpeed: 1.2,
          showTranscript: false,
          singleSentenceMode: true,
        );
        final copied = withBookmarkLoopDefaults(settings);

        expect(copied.loopWhole, isFalse);
        expect(copied.loopSentence, isTrue);
        expect(copied.sentenceLoopCount, 1);
        expect(copied.sentenceInterval, const Duration(seconds: 1));
        expect(copied.wholeLoopCount, 9);
        expect(copied.playbackSpeed, 1.2);
        expect(copied.showTranscript, isFalse);
        expect(copied.singleSentenceMode, isTrue);
      });
    });
  });
}
