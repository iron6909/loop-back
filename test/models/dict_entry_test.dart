/// DictEntry 模型测试
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/dict_entry.dart';

void main() {
  group('DictEntry', () {
    test('fromRow 解析完整数据', () {
      final entry = DictEntry.fromRow(
        word: 'abandon',
        phonetic: "ə'bændən",
        translation: 'vt. 放弃, 抛弃',
        collins: 3,
        tag: 'gk cet4 cet6 ky toefl gre',
      );

      expect(entry.word, 'abandon');
      expect(entry.phonetic, "ə'bændən");
      expect(entry.translation, 'vt. 放弃, 抛弃');
      expect(entry.collins, 3);
      expect(entry.examTags, ['CET4', 'CET6', 'TOEFL', 'GRE']);
    });

    test('fromRow 过滤非显示标签（zk/gk/ky）', () {
      final entry = DictEntry.fromRow(
        word: 'a',
        phonetic: 'ei',
        tag: 'zk gk ky',
      );

      expect(entry.examTags, isEmpty);
    });

    test('fromRow 保留 ielts 标签', () {
      final entry = DictEntry.fromRow(
        word: 'ability',
        phonetic: "ə'biləti",
        tag: 'zk gk cet4 ky toefl ielts',
      );

      expect(entry.examTags, contains('IELTS'));
      expect(entry.examTags, contains('CET4'));
      expect(entry.examTags, contains('TOEFL'));
    });

    test('fromRow 空标签', () {
      final entry = DictEntry.fromRow(word: 'test', phonetic: 'test', tag: '');

      expect(entry.examTags, isEmpty);
    });

    test('fromRow null 标签', () {
      final entry = DictEntry.fromRow(word: 'test', phonetic: 'test');

      expect(entry.examTags, isEmpty);
    });

    test('fromRow 无星级默认为 0', () {
      final entry = DictEntry.fromRow(word: 'test', phonetic: 'test');

      expect(entry.collins, 0);
    });

    test('fromRow null 翻译', () {
      final entry = DictEntry.fromRow(
        word: 'test',
        phonetic: 'test',
        translation: null,
      );

      expect(entry.translation, isNull);
    });

    test('标签顺序与原始顺序一致', () {
      final entry = DictEntry.fromRow(
        word: 'test',
        phonetic: 'test',
        tag: 'gre ielts toefl cet6 cet4',
      );

      expect(entry.examTags, ['GRE', 'IELTS', 'TOEFL', 'CET6', 'CET4']);
    });
  });
}
