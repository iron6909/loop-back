import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/sentence.dart';

void main() {
  group('Sentence', () {
    Sentence createSample({bool isBookmarked = false}) {
      return Sentence(
        index: 0,
        text: 'Hello, world!',
        startTime: const Duration(seconds: 10),
        endTime: const Duration(seconds: 15),
        isBookmarked: isBookmarked,
      );
    }

    group('toJson / fromJson 往返序列化', () {
      test('完整字段往返一致', () {
        final sentence = createSample(isBookmarked: true);
        final json = sentence.toJson();
        final restored = Sentence.fromJson(json);

        expect(restored.index, sentence.index);
        expect(restored.text, sentence.text);
        expect(restored.startTime, sentence.startTime);
        expect(restored.endTime, sentence.endTime);
        expect(restored.isBookmarked, sentence.isBookmarked);
      });

      test('startTime/endTime 以毫秒序列化', () {
        final sentence = createSample();
        final json = sentence.toJson();

        expect(json['startTime'], 10000);
        expect(json['endTime'], 15000);
      });

      test('isBookmarked 缺失时默认 false', () {
        final json = {
          'index': 0,
          'text': 'Hello',
          'startTime': 1000,
          'endTime': 2000,
          // 无 isBookmarked
        };
        final sentence = Sentence.fromJson(json);
        expect(sentence.isBookmarked, isFalse);
      });
    });

    test('duration getter 计算正确', () {
      final sentence = createSample();
      expect(sentence.duration, const Duration(seconds: 5));
    });

    test('duration getter 零长度句子', () {
      final sentence = Sentence(
        index: 0,
        text: '',
        startTime: const Duration(seconds: 5),
        endTime: const Duration(seconds: 5),
      );
      expect(sentence.duration, Duration.zero);
    });

    group('copyWith', () {
      test('部分字段覆盖', () {
        final sentence = createSample();
        final copied = sentence.copyWith(text: '新文本', isBookmarked: true);

        expect(copied.text, '新文本');
        expect(copied.isBookmarked, isTrue);
        expect(copied.index, sentence.index);
        expect(copied.startTime, sentence.startTime);
        expect(copied.endTime, sentence.endTime);
      });
    });

    test('isBookmarked 默认 false', () {
      final sentence = createSample();
      expect(sentence.isBookmarked, isFalse);
    });
  });
}
