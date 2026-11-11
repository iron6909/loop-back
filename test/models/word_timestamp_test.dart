/// WordTimestamp 模型单元测试
///
/// 验证词级时间戳仅依赖单词和时间范围，转录服务的额外字段会被忽略。
library;

import 'package:loop_back/models/word_timestamp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WordTimestamp', () {
    test('fromJson 不要求 confidence 字段', () {
      final timestamp = WordTimestamp.fromJson({
        'word': 'hello',
        'startTime': 1.5,
        'endTime': 2.0,
      });

      expect(timestamp.word, 'hello');
      expect(timestamp.startTime, const Duration(milliseconds: 1500));
      expect(timestamp.endTime, const Duration(milliseconds: 2000));
    });

    test('fromJson 忽略历史 JSON 的 confidence 字段', () {
      final timestamp = WordTimestamp.fromJson({
        'word': 'world',
        'startTime': 3,
        'endTime': 4,
        'confidence': 1,
      });

      expect(timestamp.startTime, const Duration(milliseconds: 3000));
      expect(timestamp.endTime, const Duration(milliseconds: 4000));
    });

    test('toJson 不再写入 confidence 字段', () {
      const timestamp = WordTimestamp(
        word: 'test',
        startTime: Duration(milliseconds: 1500),
        endTime: Duration(milliseconds: 2500),
      );

      expect(timestamp.toJson(), {
        'word': 'test',
        'startTime': 1.5,
        'endTime': 2.5,
      });
    });

    test('缺少必要时间字段时抛出异常', () {
      expect(
        () => WordTimestamp.fromJson({'word': 'missing'}),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('encodeWordTimestamps / decodeWordTimestamps', () {
    test('编码后解码还原一致', () {
      const words = [
        WordTimestamp(
          word: 'hello',
          startTime: Duration(milliseconds: 1500),
          endTime: Duration(milliseconds: 2000),
        ),
        WordTimestamp(
          word: 'world',
          startTime: Duration(milliseconds: 2100),
          endTime: Duration(milliseconds: 2800),
        ),
      ];

      final decoded = decodeWordTimestamps(encodeWordTimestamps(words));

      expect(decoded, isNotNull);
      expect(decoded, hasLength(2));
      expect(decoded![0].word, 'hello');
      expect(decoded[0].startTime, const Duration(milliseconds: 1500));
      expect(decoded[0].endTime, const Duration(milliseconds: 2000));
      expect(decoded[1].word, 'world');
      expect(decoded[1].startTime, const Duration(milliseconds: 2100));
      expect(decoded[1].endTime, const Duration(milliseconds: 2800));
    });

    test('空列表编码解码', () {
      expect(decodeWordTimestamps(encodeWordTimestamps([])), isEmpty);
    });

    test('非法或不完整 JSON 返回 null', () {
      expect(decodeWordTimestamps('not valid json'), isNull);
      expect(decodeWordTimestamps('[{"bad": true}]'), isNull);
      expect(decodeWordTimestamps('{"key": "value"}'), isNull);
    });
  });
}
