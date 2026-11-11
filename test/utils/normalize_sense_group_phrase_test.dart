import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/widgets/practice/sense_group_text.dart';

void main() {
  group('normalizeSenseGroupPhrase', () {
    test('小写 + trim', () {
      expect(normalizeSenseGroupPhrase('  In The Morning  '), 'in the morning');
    });

    test('去句末标点', () {
      expect(normalizeSenseGroupPhrase('Hello world.'), 'hello world');
      expect(normalizeSenseGroupPhrase('really?'), 'really');
      expect(normalizeSenseGroupPhrase('wow!'), 'wow');
      expect(normalizeSenseGroupPhrase('first, second,'), 'first, second');
      expect(normalizeSenseGroupPhrase('end;'), 'end');
      expect(normalizeSenseGroupPhrase('end:'), 'end');
    });

    test('保留撇号', () {
      expect(normalizeSenseGroupPhrase("don't"), "don't");
      expect(normalizeSenseGroupPhrase("I'd like to"), "i'd like to");
      expect(normalizeSenseGroupPhrase("it's"), "it's");
    });

    test('保留内部标点', () {
      expect(
        normalizeSenseGroupPhrase('my project— well,'),
        'my project— well',
      );
      expect(normalizeSenseGroupPhrase('first, second'), 'first, second');
    });

    test('多个尾部标点', () {
      expect(normalizeSenseGroupPhrase('really?!'), 'really');
      expect(normalizeSenseGroupPhrase('end...'), 'end');
    });

    test('空字符串', () {
      expect(normalizeSenseGroupPhrase(''), '');
      expect(normalizeSenseGroupPhrase('  '), '');
    });

    test('纯标点', () {
      expect(normalizeSenseGroupPhrase('.'), '');
      expect(normalizeSenseGroupPhrase('...'), '');
    });
  });
}
