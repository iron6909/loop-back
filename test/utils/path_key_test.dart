import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/utils/path_key.dart';

void main() {
  group('pathKey', () {
    test('Windows 与 POSIX 分隔符指向同一文件时得到同一个键', () {
      expect(
        pathKey(r'audios\imported\x.mp3'),
        pathKey('audios/imported/x.mp3'),
      );
    });

    test('绝对路径同样归一（同一文件两种写法）', () {
      expect(
        pathKey(r'C:\data\audios\Example - Kept.m4a'),
        pathKey('C:/data/audios/Example - Kept.m4a'),
      );
    });

    test('折叠 . 与 .. 冗余段', () {
      expect(
        pathKey('audios/./imported/../imported/x.mp3'),
        pathKey('audios/imported/x.mp3'),
      );
    });

    test('空串原样返回，不当成 "."', () {
      expect(pathKey(''), '');
    });
  });
}
