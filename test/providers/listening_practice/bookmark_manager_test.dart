import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/sentence.dart';
import 'package:loop_back/providers/listening_practice/bookmark_manager.dart';

void main() {
  group('BookmarkManager', () {
    Sentence createSentence(int index, String text) {
      return Sentence(
        index: index,
        text: text,
        startTime: Duration(seconds: index * 5),
        endTime: Duration(seconds: (index + 1) * 5),
      );
    }

    group('updateSentenceBookmarkStatus', () {
      test('正确设置 isBookmarked 标志', () {
        final sentences = [
          createSentence(0, 'A'),
          createSentence(1, 'B'),
          createSentence(2, 'C'),
        ];
        BookmarkManager.updateSentenceBookmarkStatus(sentences, {0, 2});

        expect(sentences[0].isBookmarked, isTrue);
        expect(sentences[1].isBookmarked, isFalse);
        expect(sentences[2].isBookmarked, isTrue);
      });

      test('不在 set 中的句子标记为 false', () {
        final sentences = [
          createSentence(0, 'A')..isBookmarked = true,
          createSentence(1, 'B')..isBookmarked = true,
        ];
        // 空集合 → 全部设为 false
        BookmarkManager.updateSentenceBookmarkStatus(sentences, {});

        expect(sentences[0].isBookmarked, isFalse);
        expect(sentences[1].isBookmarked, isFalse);
      });
    });

    group('createSentenceBookmarkSnapshot', () {
      test('创建收藏状态副本且不修改共享字幕对象', () {
        final source = [
          createSentence(0, 'A'),
          createSentence(1, 'B')..isBookmarked = true,
          createSentence(2, 'C'),
        ];

        final snapshot = BookmarkManager.createSentenceBookmarkSnapshot(
          source,
          {0, 2},
        );

        expect(snapshot.map((sentence) => sentence.isBookmarked), [
          true,
          false,
          true,
        ]);
        expect(snapshot.map((sentence) => sentence.index), [0, 1, 2]);
        expect(identical(snapshot[0], source[0]), isFalse);
        expect(source.map((sentence) => sentence.isBookmarked), [
          false,
          true,
          false,
        ]);
      });

      test('保留段落结构并为每句创建独立副本', () {
        final source = [
          [createSentence(0, 'A'), createSentence(1, 'B')],
          [createSentence(2, 'C')],
        ];

        final snapshot = BookmarkManager.createParagraphBookmarkSnapshot(
          source,
          {1, 2},
        );

        expect(snapshot.map((paragraph) => paragraph.length), [2, 1]);
        expect(
          snapshot
              .expand((paragraph) => paragraph)
              .map((sentence) => sentence.isBookmarked),
          [false, true, true],
        );
        expect(identical(snapshot[0][0], source[0][0]), isFalse);
      });
    });

    group('toggleBookmark', () {
      test('添加新书签（isRemoving=false）', () {
        final sentences = [createSentence(0, 'A'), createSentence(1, 'B')];
        final (isRemoving, indicesToRemove, nextIndex) =
            BookmarkManager.toggleBookmark(0, sentences, {}, false);

        expect(isRemoving, isFalse);
        expect(indicesToRemove, isEmpty);
        expect(nextIndex, isNull);
      });

      test('移除已有书签（isRemoving=true）', () {
        final sentences = [
          createSentence(0, 'A'),
          createSentence(1, 'B'),
          createSentence(2, 'C'),
        ];
        final (isRemoving, indicesToRemove, nextIndex) =
            BookmarkManager.toggleBookmark(0, sentences, {0, 1, 2}, false);

        expect(isRemoving, isTrue);
        expect(indicesToRemove.contains(0), isTrue);
      });

      test('智能去重：同文本不同大小写的句子一起移除', () {
        final sentences = [
          createSentence(0, 'Hello'),
          createSentence(1, 'hello'),
          createSentence(2, 'World'),
        ];
        // 所有句子都是书签
        final (isRemoving, indicesToRemove, _) = BookmarkManager.toggleBookmark(
          0,
          sentences,
          {0, 1, 2},
          false,
        );

        expect(isRemoving, isTrue);
        // 'Hello' 和 'hello' 标准化后相同，都应被移除
        expect(indicesToRemove, contains(0));
        expect(indicesToRemove, contains(1));
        expect(indicesToRemove.contains(2), isFalse);
      });

      test('智能去重：同文本不同标点的句子一起移除', () {
        final sentences = [
          createSentence(0, 'Hello!'),
          createSentence(1, 'Hello'),
          createSentence(2, ',Hello.'),
        ];
        final result = BookmarkManager.toggleBookmark(0, sentences, {
          0,
          1,
          2,
        }, false);
        final indicesToRemove = result.$2;

        // 标准化后 'Hello!', 'Hello', ',Hello.' 都是 'hello'
        expect(indicesToRemove, {0, 1, 2});
      });

      test('书签模式下计算 nextIndex（跳过将被移除的）', () {
        final sentences = [
          createSentence(0, 'A'),
          createSentence(1, 'B'),
          createSentence(2, 'C'),
        ];
        // 书签模式下，移除索引 0，下一个应该是索引 1
        final result = BookmarkManager.toggleBookmark(0, sentences, {
          0,
          1,
          2,
        }, true);
        final nextIndex = result.$3;

        expect(nextIndex, isNotNull);
        expect(nextIndex, 1);
      });

      test('非书签模式 nextIndex 为 null', () {
        final sentences = [createSentence(0, 'A'), createSentence(1, 'B')];
        final result = BookmarkManager.toggleBookmark(0, sentences, {
          0,
          1,
        }, false);
        final nextIndex = result.$3;

        expect(nextIndex, isNull);
      });

      test('书签模式移除最后一个书签时 nextIndex 为 null', () {
        final sentences = [createSentence(0, 'A')];
        final result = BookmarkManager.toggleBookmark(0, sentences, {0}, true);
        final nextIndex = result.$3;

        expect(nextIndex, isNull);
      });

      test('书签模式移除末尾书签但前面仍有收藏时回退到前一个', () {
        final sentences = [
          createSentence(0, 'A'),
          createSentence(1, 'B'),
          createSentence(2, 'C'),
          createSentence(3, 'D'),
        ];
        final result = BookmarkManager.toggleBookmark(3, sentences, {
          0,
          1,
          3,
        }, true);

        expect(result.$2, {3});
        expect(result.$3, 1);
      });

      test('书签模式移除后跳过同文本书签找到下一个', () {
        final sentences = [
          createSentence(0, 'Same'),
          createSentence(1, 'Same'),
          createSentence(2, 'Different'),
        ];
        // 移除索引 0，索引 1 同文本也会被移除，下一个应该是索引 2
        final (_, indicesToRemove, nextIndex) = BookmarkManager.toggleBookmark(
          0,
          sentences,
          {0, 1, 2},
          true,
        );

        expect(indicesToRemove, {0, 1});
        expect(nextIndex, 2);
      });
    });
  });
}
