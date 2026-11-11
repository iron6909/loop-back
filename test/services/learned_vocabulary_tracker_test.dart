import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/sentence.dart';
import 'package:loop_back/services/learned_vocabulary_tracker.dart';

void main() {
  group('LearnedVocabularyTracker.extractWordForms', () {
    test('保留不同词形，不做 lemma 合并', () {
      expect(
        LearnedVocabularyTracker.extractWordForms('Child children running run'),
        {'child', 'children', 'running', 'run'},
      );
    });

    test('保留内部撇号和连字符，忽略数字与符号', () {
      expect(
        LearnedVocabularyTracker.extractWordForms(
          "Don't stop mother-in-law 2026 !!!",
        ),
        {"don't", 'stop', 'mother-in-law'},
      );
    });
  });

  group('LearnedVocabularyTracker', () {
    test('recordSentence + flush 会批量去重写入', () async {
      final persisted = <Map<String, DateTime>>[];
      final tracker = LearnedVocabularyTracker(
        persistWordForms: (wordForms) async {
          persisted.add(Map<String, DateTime>.from(wordForms));
        },
        onStatsUpdated: () {},
        flushDelay: const Duration(minutes: 1),
      );

      await tracker.recordSentence('Child child children');
      await tracker.recordSentence('children RUN');
      await tracker.flush();

      expect(persisted, hasLength(1));
      expect(persisted.single.keys.toSet(), {'child', 'children', 'run'});
    });

    test('recordSentences 会合并多句词形后写入', () async {
      final persisted = <Map<String, DateTime>>[];
      final tracker = LearnedVocabularyTracker(
        persistWordForms: (wordForms) async {
          persisted.add(Map<String, DateTime>.from(wordForms));
        },
        onStatsUpdated: () {},
        flushDelay: const Duration(minutes: 1),
      );

      await tracker.recordSentences([
        Sentence(
          index: 0,
          text: 'Child children',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
        ),
        Sentence(
          index: 1,
          text: "Don't run",
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 2),
        ),
      ]);
      await tracker.flush();

      expect(persisted.single.keys.toSet(), {
        'child',
        'children',
        "don't",
        'run',
      });
    });

    test('写库失败时不向播放层抛错', () async {
      Object? capturedError;
      final tracker = LearnedVocabularyTracker(
        persistWordForms: (_) async {
          throw StateError('db failed');
        },
        onStatsUpdated: () {},
        flushDelay: const Duration(minutes: 1),
        onError: (error, _) {
          capturedError = error;
        },
      );

      await tracker.recordSentence('child');
      await tracker.flush();

      expect(capturedError, isA<StateError>());
    });
  });
}
