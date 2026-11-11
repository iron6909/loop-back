import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/audio_item.dart';
import 'package:loop_back/models/sentence.dart';
import 'package:loop_back/models/playback_settings.dart';
import 'package:loop_back/models/listening_practice_state.dart';

void main() {
  group('ListeningPracticeState', () {
    final sampleAudio = AudioItem(
      id: 'audio-1',
      name: '测试音频',
      audioPath: 'audios/test.mp3',
      addedDate: DateTime(2026, 1, 15),
    );

    List<Sentence> createSentences(int count) {
      return List.generate(
        count,
        (i) => Sentence(
          index: i,
          text: '句子 $i',
          startTime: Duration(seconds: i * 5),
          endTime: Duration(seconds: (i + 1) * 5),
        ),
      );
    }

    group('默认值', () {
      test('所有默认值符合预期', () {
        const state = ListeningPracticeState();

        expect(state.currentAudioItem, isNull);
        expect(state.sentences, isEmpty);
        expect(state.currentFullIndex, isNull);
        expect(state.currentBookmarkIndex, isNull);
        expect(state.lastPlayedFullIndex, isNull);
        expect(state.lastPlayedBookmarkIndex, isNull);
        expect(state.settings, isA<PlaybackSettings>());
        expect(state.fullSettings, isA<PlaybackSettings>());
        expect(state.bookmarkSettings, isA<PlaybackSettings>());
        expect(state.fullSettings.loopSentence, isFalse);
        expect(state.bookmarkSettings.loopSentence, isTrue);
        expect(state.bookmarkSettings.sentenceLoopCount, 1);
        expect(
          state.bookmarkSettings.sentenceInterval,
          const Duration(seconds: 1),
        );
        expect(state.playlistMode, PlaylistMode.full);
        expect(state.bookmarkedIndices, isEmpty);
        expect(state.isLoading, isFalse);
      });
    });

    group('copyWith 正常字段', () {
      test('部分字段覆盖', () {
        const state = ListeningPracticeState();
        final sentences = createSentences(3);
        final copied = state.copyWith(
          currentAudioItem: sampleAudio,
          sentences: sentences,
          currentFullIndex: 1,
          isLoading: true,
        );

        expect(copied.currentAudioItem, sampleAudio);
        expect(copied.sentences, sentences);
        expect(copied.currentFullIndex, 1);
        expect(copied.isLoading, isTrue);
        // 未修改保持原值
        expect(copied.playlistMode, PlaylistMode.full);
      });

      test('settings 仅更新当前激活 tab 的设置', () {
        const state = ListeningPracticeState(
          fullSettings: PlaybackSettings(playbackSpeed: 1.0),
          bookmarkSettings: PlaybackSettings(playbackSpeed: 0.8),
          playlistMode: PlaylistMode.bookmarks,
        );

        final copied = state.copyWith(
          settings: const PlaybackSettings(playbackSpeed: 1.5),
        );

        expect(copied.fullSettings.playbackSpeed, 1.0);
        expect(copied.bookmarkSettings.playbackSpeed, 1.5);
        expect(copied.settings.playbackSpeed, 1.5);
      });
    });

    group('copyWith clear* 标志', () {
      test('clearCurrentAudioItem 设置为 null', () {
        final state = ListeningPracticeState(currentAudioItem: sampleAudio);
        final copied = state.copyWith(clearCurrentAudioItem: true);

        expect(copied.currentAudioItem, isNull);
      });

      test('clearCurrentFullIndex 设置为 null', () {
        const state = ListeningPracticeState(currentFullIndex: 5);
        final copied = state.copyWith(clearCurrentFullIndex: true);

        expect(copied.currentFullIndex, isNull);
      });

      test('clearCurrentBookmarkIndex 设置为 null', () {
        const state = ListeningPracticeState(currentBookmarkIndex: 3);
        final copied = state.copyWith(clearCurrentBookmarkIndex: true);

        expect(copied.currentBookmarkIndex, isNull);
      });

      test('clearLastPlayedFullIndex 设置为 null', () {
        const state = ListeningPracticeState(lastPlayedFullIndex: 2);
        final copied = state.copyWith(clearLastPlayedFullIndex: true);

        expect(copied.lastPlayedFullIndex, isNull);
      });

      test('clearLastPlayedBookmarkIndex 设置为 null', () {
        const state = ListeningPracticeState(lastPlayedBookmarkIndex: 4);
        final copied = state.copyWith(clearLastPlayedBookmarkIndex: true);

        expect(copied.lastPlayedBookmarkIndex, isNull);
      });

      test('clear 标志优先于传入值', () {
        const state = ListeningPracticeState(currentFullIndex: 5);
        final copied = state.copyWith(
          currentFullIndex: 10,
          clearCurrentFullIndex: true,
        );
        // clear 标志优先
        expect(copied.currentFullIndex, isNull);
      });
    });

    group('bookmarkedSentences 计算属性', () {
      test('正确过滤书签句子', () {
        final sentences = createSentences(5);
        final state = ListeningPracticeState(
          sentences: sentences,
          bookmarkedIndices: {0, 2, 4},
        );
        final bookmarked = state.bookmarkedSentences;

        expect(bookmarked.length, 3);
        expect(bookmarked[0].index, 0);
        expect(bookmarked[1].index, 2);
        expect(bookmarked[2].index, 4);
      });

      test('无书签时返回空列表', () {
        final sentences = createSentences(3);
        final state = ListeningPracticeState(sentences: sentences);

        expect(state.bookmarkedSentences, isEmpty);
      });

      test('无句子时返回空列表', () {
        const state = ListeningPracticeState(bookmarkedIndices: {0, 1});

        expect(state.bookmarkedSentences, isEmpty);
      });
    });

    group('currentSentence', () {
      test('full 模式下根据 currentFullIndex 返回句子', () {
        final sentences = createSentences(5);
        final state = ListeningPracticeState(
          sentences: sentences,
          currentFullIndex: 2,
          playlistMode: PlaylistMode.full,
        );

        expect(state.currentSentence, isNotNull);
        expect(state.currentSentence!.index, 2);
      });

      test('currentFullIndex 为 null 时返回 null', () {
        final sentences = createSentences(3);
        final state = ListeningPracticeState(sentences: sentences);

        expect(state.currentSentence, isNull);
      });

      test('currentFullIndex 超出范围时返回 null', () {
        final sentences = createSentences(3);
        const state = ListeningPracticeState(currentFullIndex: 10);
        // 用 copyWith 设置句子，因为 const 构造函数不能用非 const 参数
        final stateWithSentences = state.copyWith(sentences: sentences);

        expect(stateWithSentences.currentSentence, isNull);
      });

      test('bookmarks 模式下 settings 返回 bookmarkSettings', () {
        const state = ListeningPracticeState(
          playlistMode: PlaylistMode.bookmarks,
          fullSettings: PlaybackSettings(playbackSpeed: 1.2),
          bookmarkSettings: PlaybackSettings(playbackSpeed: 0.8),
        );

        expect(state.settings.playbackSpeed, 0.8);
      });
    });

    group('hasAudio / hasSentences', () {
      test('hasAudio 有音频时返回 true', () {
        final state = ListeningPracticeState(currentAudioItem: sampleAudio);
        expect(state.hasAudio, isTrue);
      });

      test('hasAudio 无音频时返回 false', () {
        const state = ListeningPracticeState();
        expect(state.hasAudio, isFalse);
      });

      test('hasSentences 有句子时返回 true', () {
        final state = ListeningPracticeState(sentences: createSentences(1));
        expect(state.hasSentences, isTrue);
      });

      test('hasSentences 无句子时返回 false', () {
        const state = ListeningPracticeState();
        expect(state.hasSentences, isFalse);
      });
    });

    group('isFirstSentence / isLastSentence', () {
      test('全文模式：第一句', () {
        final state = ListeningPracticeState(
          sentences: createSentences(3),
          currentFullIndex: 0,
        );
        expect(state.isFirstSentence, isTrue);
        expect(state.isLastSentence, isFalse);
      });

      test('全文模式：中间句', () {
        final state = ListeningPracticeState(
          sentences: createSentences(3),
          currentFullIndex: 1,
        );
        expect(state.isFirstSentence, isFalse);
        expect(state.isLastSentence, isFalse);
      });

      test('全文模式：最后一句', () {
        final state = ListeningPracticeState(
          sentences: createSentences(3),
          currentFullIndex: 2,
        );
        expect(state.isFirstSentence, isFalse);
        expect(state.isLastSentence, isTrue);
      });

      test('收藏模式：按收藏句子位置判定首/末句', () {
        final sentences = createSentences(5);
        final first = ListeningPracticeState(
          sentences: sentences,
          bookmarkedIndices: const {1, 3},
          currentBookmarkIndex: 1,
          playlistMode: PlaylistMode.bookmarks,
        );
        expect(first.isFirstSentence, isTrue);
        expect(first.isLastSentence, isFalse);

        final last = first.copyWith(currentBookmarkIndex: 3);
        expect(last.isFirstSentence, isFalse);
        expect(last.isLastSentence, isTrue);
      });

      test('无句子时首末句均为 true', () {
        const state = ListeningPracticeState();
        expect(state.isFirstSentence, isTrue);
        expect(state.isLastSentence, isTrue);
      });

      test('收藏模式无收藏句时首末句均为 true', () {
        final state = ListeningPracticeState(
          sentences: createSentences(3),
          playlistMode: PlaylistMode.bookmarks,
        );
        expect(state.isFirstSentence, isTrue);
        expect(state.isLastSentence, isTrue);
      });
    });
  });
}
