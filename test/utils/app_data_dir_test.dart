import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/utils/app_data_dir.dart';

void main() {
  test('ASR crash marker 位于 logs 目录并创建目录', () async {
    final tempDir = await Directory.systemTemp.createTemp('app-data-dir-test-');
    addTearDown(() async {
      appDataDirectoryOverride = null;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });
    appDataDirectoryOverride = tempDir;

    final path = await asrInferenceLogDirectoryPath();

    expect(path, '${tempDir.path}/logs');
    expect(await Directory('${tempDir.path}/logs').exists(), isTrue);
  });
}
