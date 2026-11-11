import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/utils/stopwords.dart';

void main() {
  group('isStopword', () {
    test('小写停用词返回 true', () {
      expect(isStopword('the'), isTrue);
      expect(isStopword('and'), isTrue);
      expect(isStopword('with'), isTrue);
      expect(isStopword('from'), isTrue);
      expect(isStopword('have'), isTrue);
    });

    test('大小写不敏感', () {
      expect(isStopword('The'), isTrue);
      expect(isStopword('AND'), isTrue);
      expect(isStopword('With'), isTrue);
    });

    test('带标点的停用词也能识别', () {
      expect(isStopword('the,'), isTrue);
      expect(isStopword('and.'), isTrue);
      expect(isStopword('"with"'), isTrue);
      expect(isStopword('(from)'), isTrue);
      expect(isStopword('the;'), isTrue);
    });

    test('非停用词返回 false', () {
      expect(isStopword('beautiful'), isFalse);
      expect(isStopword('sunset'), isFalse);
      expect(isStopword('algorithm'), isFalse);
      expect(isStopword('practice'), isFalse);
    });

    test('空字符串返回 false', () {
      expect(isStopword(''), isFalse);
    });

    test('纯标点返回 false', () {
      expect(isStopword('...'), isFalse);
      expect(isStopword(','), isFalse);
    });
  });
}
