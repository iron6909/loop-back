/// 句内分词与词级选区纯逻辑测试
library;

import 'package:loop_back/utils/saved_text_index.dart';
import 'package:loop_back/utils/text_normalize.dart';
import 'package:loop_back/widgets/practice/sentence_word_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tokenizeSentence', () {
    test('按空白/非空白切分并记录字符区间', () {
      final tokens = tokenizeSentence('Hello, world!');
      expect(tokens.map((t) => t.text).toList(), ['Hello,', ' ', 'world!']);
      expect(tokens[0].start, 0);
      expect(tokens[0].end, 6);
      expect(tokens[1].start, 6);
      expect(tokens[1].end, 7);
      expect(tokens[2].start, 7);
      expect(tokens[2].end, 13);
    });

    test('词判定：含字母/数字为词，纯标点与空白不是词', () {
      final tokens = tokenizeSentence('go — stop... 3rd');
      expect(tokens.map((t) => t.text).toList(), [
        'go',
        ' ',
        '—',
        ' ',
        'stop...',
        ' ',
        '3rd',
      ]);
      expect(tokens[0].isWord, isTrue);
      expect(tokens[1].isWord, isFalse); // 空白
      expect(tokens[2].isWord, isFalse); // 纯标点破折号
      expect(tokens[4].isWord, isTrue); // stop...（含字母）
      expect(tokens[6].isWord, isTrue); // 3rd（含数字）
    });

    test('多空白/换行保留为单个空白 token', () {
      final tokens = tokenizeSentence('a  b\nc');
      expect(tokens.map((t) => t.text).toList(), ['a', '  ', 'b', '\n', 'c']);
    });

    test('空字符串返回空列表', () {
      expect(tokenizeSentence(''), isEmpty);
    });
  });

  group('wordTokenAtChar', () {
    final tokens = tokenizeSentence('go stop');

    test('词内返回索引，空白返回 -1', () {
      expect(wordTokenAtChar(tokens, 0), 0);
      expect(wordTokenAtChar(tokens, 2), -1); // 空格
      expect(wordTokenAtChar(tokens, 3), 2);
    });

    test('越界返回 -1', () {
      expect(wordTokenAtChar(tokens, 7), -1);
      expect(wordTokenAtChar(tokens, -1), -1);
    });
  });

  group('hasDictionaryLookupContent', () {
    test('空白、标点和符号没有查词语义', () {
      expect(hasDictionaryLookupContent('   \n'), isFalse);
      expect(hasDictionaryLookupContent('.,!? —…'), isFalse);
      expect(hasDictionaryLookupContent('★ →'), isFalse);
    });

    test('字母数字和内部标点词组保留查词语义', () {
      expect(hasDictionaryLookupContent('co-op'), isTrue);
      expect(hasDictionaryLookupContent('well, you know'), isTrue);
      expect(hasDictionaryLookupContent('123'), isTrue);
    });

    test('归一化后被剥空的文本不可查（否则面板会拿空串查询）', () {
      // normalizeWord 的边缘剥离是 ASCII 语义，纯 CJK 会被剥成空串。
      expect(normalizeWord('你好'), isEmpty);
      expect(hasDictionaryLookupContent('你好'), isFalse);
      expect(hasDictionaryLookupContent('日本語'), isFalse);
      expect(hasDictionaryLookupContent('。，！'), isFalse);
    });

    test('与点词判定同源：门控结果恒等于 token 的 isWord', () {
      const cases = [
        'co-op',
        'e.g.',
        'stop...',
        '3rd',
        '—',
        '...',
        '你好',
        '日本語',
        'café',
        'naïve',
        "dogs'",
        "'quoted'",
      ];
      for (final text in cases) {
        final tokens = tokenizeSentence(text);
        expect(
          tokens.single.isWord,
          hasDictionaryLookupContent(text),
          reason: '「$text」的可点判定与查词门控必须一致',
        );
      }
    });

    test('已知限制：词首尾的非 ASCII 字母被剥掉，词中间的不受影响', () {
      expect(normalizeWord('café'), 'caf');
      expect(normalizeWord('résumé'), 'résum');
      expect(normalizeWord('naïve'), 'naïve');
      // 仍可查（含 ASCII 字母），只是查的是被剥过的词形。
      expect(hasDictionaryLookupContent('café'), isTrue);
    });
  });

  group('savedCharRanges', () {
    /// 便捷调用：从原始 key 集合建索引，返回命中区间对应的原文子串列表
    List<String> hitTexts(
      String text, {
      Set<String> words = const {},
      Set<String> phrases = const {},
    }) {
      final index = SavedTextIndex.build(
        savedWords: words,
        savedPhrases: phrases,
      );
      final ranges = savedCharRanges(text, tokenizeSentence(text), index);
      return ranges.map((r) => text.substring(r.$1, r.$2)).toList();
    }

    test('空集合返回空区间', () {
      expect(hitTexts('The quick fox.'), isEmpty);
    });

    test('单词命中（大小写不敏感）', () {
      expect(hitTexts('The Quick fox.', words: {'quick'}), ['Quick']);
    });

    test('未收藏词不命中', () {
      expect(hitTexts('The quick fox.', words: {'lazy'}), isEmpty);
    });

    test('命中区间修边：不覆盖首尾标点', () {
      expect(hitTexts('I saw a fox.', words: {'fox'}), ['fox']);
      expect(hitTexts('He said "fox", right?', words: {'fox'}), ['fox']);
    });

    test('尾部直撇号保留（所有格，与 normalizeWord 一致）', () {
      expect(hitTexts("the dogs' bone", words: {"dogs'"}), ["dogs'"]);
    });

    test('弯撇号命中且修边保留（排版文本 dogs’ 匹配直撇号 key）', () {
      expect(hitTexts('the dogs’ bone', words: {"dogs'"}), ['dogs’']);
    });

    test('引用尾单引号不进入命中区间', () {
      expect(hitTexts("about 'onto something'?", phrases: {'onto something'}), [
        'onto something',
      ]);
    });

    test('key 未归一化也命中（本地词典 headword 带点号，如 e.g.）', () {
      expect(hitTexts('See e.g., the appendix.', words: {'e.g.'}), ['e.g']);
    });

    test('重音字母不被修边截断（café 经归一化 caf 命中后完整标记）', () {
      expect(hitTexts('a café, nearby', words: {'caf'}), ['café']);
    });

    test('多词收藏词命中（滑动窗口，区间横跨词间空白）', () {
      expect(
        hitTexts('I need to figure out the answer.', words: {'figure out'}),
        ['figure out'],
      );
    });

    test('词间夹标点不误报', () {
      expect(hitTexts('figure, out of ten', words: {'figure out'}), isEmpty);
    });

    test('候选内部多空格折叠后命中单空格 key', () {
      expect(hitTexts('please figure  out now', words: {'figure out'}), [
        'figure  out',
      ]);
    });

    test('意群命中（key 与候选统一 normalizeWord 归一化）', () {
      expect(
        hitTexts('He jumps over the lazy dog.', phrases: {'over the lazy dog'}),
        ['over the lazy dog'],
      );
    });

    test('引号/括号语境的意群也命中（统一归一化剥边缘标点）', () {
      expect(hitTexts('He said "beautiful" twice.', phrases: {'beautiful'}), [
        'beautiful',
      ]);
      expect(
        hitTexts('so ("over the lazy dog")!', phrases: {'over the lazy dog'}),
        ['over the lazy dog'],
      );
    });

    test('单词形式的意群也命中', () {
      expect(hitTexts('Simply beautiful.', phrases: {'beautiful'}), [
        'beautiful',
      ]);
    });

    test('单词与词组重叠时两个区间都返回', () {
      final hits = hitTexts('figure out now', words: {'figure', 'figure out'});
      expect(hits, containsAll(['figure', 'figure out']));
    });

    test('长意群无词数上限（9 词意群正常命中）', () {
      const phrase = 'one two three four five six seven eight nine';
      expect(hitTexts('say $phrase again', phrases: {phrase}), [phrase]);
    });

    test('词组长于句子时安全不命中', () {
      expect(hitTexts('too short', words: {'a b c d e'}), isEmpty);
    });
  });

  group('charMaskFromRanges / splitByMask', () {
    test('区间内为 true、区间外为 false，越界安全', () {
      final mask = charMaskFromRanges(5, [(1, 3), (4, 9)]);
      expect(mask, [false, true, true, false, true]);
    });

    test('splitByMask 按翻转点切分', () {
      final mask = [false, true, true, false];
      expect(splitByMask(0, 4, mask), [
        (0, 1, false),
        (1, 3, true),
        (3, 4, false),
      ]);
    });

    test('splitByMask 空掩码/越界视为未命中', () {
      expect(splitByMask(2, 5, const []), [(2, 5, false)]);
      expect(splitByMask(0, 4, [true, true]), [(0, 2, true), (2, 4, false)]);
    });
  });

  group('savedWordSegments', () {
    Map<int, List<(int, int, bool)>> segments(
      String text, {
      Set<String> words = const {},
      Set<String> phrases = const {},
    }) {
      return savedWordSegments(
        text,
        SavedTextIndex.build(savedWords: words, savedPhrases: phrases),
      );
    }

    test('空索引/无命中返回空 map', () {
      expect(segments('The quick fox.'), isEmpty);
      expect(segments('The quick fox.', words: {'lazy'}), isEmpty);
    });

    test('单词命中：词序号与空白分词一致，子段偏移相对词首', () {
      final result = segments('The quick fox.', words: {'quick'});
      expect(result.keys, [1]);
      expect(result[1], [(0, 5, true)]);
    });

    test('带标点词只标记词本体（"fox." 的句号不命中）', () {
      final result = segments('I saw a fox.', words: {'fox'});
      expect(result.keys, [3]);
      // "fox." 内：fox 命中、句号不命中
      expect(result[3], [(0, 3, true), (3, 4, false)]);
    });

    test('词组命中：跨词的每个词各自出现在结果中', () {
      final result = segments('please figure out now', words: {'figure out'});
      expect(result.keys, containsAll([1, 2]));
      expect(result.containsKey(0), isFalse);
      expect(result.containsKey(3), isFalse);
      expect(result[1], [(0, 6, true)]);
      expect(result[2], [(0, 3, true)]);
    });

    test('引号语境命中且修边（词序号按含标点的原词计）', () {
      final result = segments(
        'He said "beautiful" twice.',
        words: {'beautiful'},
      );
      // "beautiful" 是第 2 个词（0-based），引号不命中
      expect(result.keys, [2]);
      expect(result[2], [(0, 1, false), (1, 10, true), (10, 11, false)]);
    });
  });
}
