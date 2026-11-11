import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/utils/file_size.dart';

void main() {
  group('formatBytes', () {
    test('字节', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('KB', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
    });

    test('MB', () {
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes((1.5 * 1024 * 1024).toInt()), '1.5 MB');
    });

    test('GB', () {
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
      expect(formatBytes((2.3 * 1024 * 1024 * 1024).toInt()), '2.3 GB');
    });
  });

  group('calculateDirectorySize', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dir_size_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('空目录返回 0', () async {
      expect(await calculateDirectorySize(tempDir), 0);
    });

    test('计算单个文件大小', () async {
      final file = File('${tempDir.path}/test.bin');
      file.writeAsBytesSync(List.filled(1024, 0));

      expect(await calculateDirectorySize(tempDir), 1024);
    });

    test('递归计算子目录文件大小', () async {
      final subDir = Directory('${tempDir.path}/sub')..createSync();
      File('${tempDir.path}/a.bin').writeAsBytesSync(List.filled(100, 0));
      File('${subDir.path}/b.bin').writeAsBytesSync(List.filled(200, 0));

      expect(await calculateDirectorySize(tempDir), 300);
    });

    test('不存在的目录返回 0', () async {
      final noDir = Directory('${tempDir.path}/nonexistent');
      expect(await calculateDirectorySize(noDir), 0);
    });
  });
}
