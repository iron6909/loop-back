import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/services/audio_export_service.dart';

void main() {
  late AudioExportService service;
  late Directory tempDir;

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    service = AudioExportService();
    tempDir = Directory.systemTemp.createTempSync('export_test_');

    // Mock path_provider 的 getTemporaryDirectory
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (call.method == 'getTemporaryDirectory') {
              return tempDir.path;
            }
            return null;
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('sanitizeFileName', () {
    test('正常名称不变', () {
      expect(service.sanitizeFileName('TPO-32-L4'), 'TPO-32-L4');
    });

    test('替换非法字符为下划线', () {
      expect(service.sanitizeFileName('test/file:name'), 'test_file_name');
    });

    test('合并连续下划线', () {
      expect(service.sanitizeFileName('a///b'), 'a_b');
    });

    test('处理所有非法字符', () {
      expect(
        service.sanitizeFileName(r'a\b:c*d?e"f<g>h|i'),
        'a_b_c_d_e_f_g_h_i',
      );
    });

    test('去除首尾空白', () {
      expect(service.sanitizeFileName('  hello  '), 'hello');
    });

    test('空名称返回 export', () {
      expect(service.sanitizeFileName(''), 'export');
      expect(service.sanitizeFileName('///'), 'export');
    });

    test('超长名称截断至 200 字符', () {
      final longName = 'a' * 300;
      expect(service.sanitizeFileName(longName).length, 200);
    });
  });

  group('exportAudioItem', () {
    late File audioFile;
    late File transcriptFile;

    setUp(() {
      audioFile = File('${tempDir.path}/source.mp3');
      audioFile.writeAsBytesSync([0x01, 0x02, 0x03]);

      transcriptFile = File('${tempDir.path}/source.srt');
      transcriptFile.writeAsStringSync(
        '1\n00:00:01,000 --> 00:00:02,000\nHello\n',
      );
    });

    test('仅导出音频文件', () async {
      final result = await service.exportAudioItem(
        displayName: 'Test Audio',
        audioPath: audioFile.path,
        transcriptPath: transcriptFile.path,
        includeAudio: true,
        includeTranscript: false,
      );

      expect(File(result).existsSync(), true);
      expect(result.endsWith('Test Audio.mp3'), true);
    });

    test('仅导出字幕文件', () async {
      final result = await service.exportAudioItem(
        displayName: 'Test Audio',
        audioPath: audioFile.path,
        transcriptPath: transcriptFile.path,
        includeAudio: false,
        includeTranscript: true,
      );

      expect(File(result).existsSync(), true);
      expect(result.endsWith('Test Audio.srt'), true);
    });

    test('导出 ZIP 包含音频和字幕', () async {
      final result = await service.exportAudioItem(
        displayName: 'Test Audio',
        audioPath: audioFile.path,
        transcriptPath: transcriptFile.path,
        includeAudio: true,
        includeTranscript: true,
      );

      expect(File(result).existsSync(), true);
      expect(result.endsWith('Test Audio.zip'), true);

      // 验证 ZIP 内容
      final zipBytes = File(result).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(zipBytes);
      final names = archive.files.map((f) => f.name).toList();
      expect(names, containsAll(['Test Audio.mp3', 'Test Audio.srt']));
    });

    test('文件名含特殊字符时自动清理', () async {
      final result = await service.exportAudioItem(
        displayName: 'TPO/32:L4',
        audioPath: audioFile.path,
        includeAudio: true,
        includeTranscript: false,
      );

      expect(result.contains('TPO_32_L4.mp3'), true);
    });

    test('两项都未选时抛出异常', () {
      expect(
        () => service.exportAudioItem(
          displayName: 'Test',
          audioPath: audioFile.path,
          includeAudio: false,
          includeTranscript: false,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('选择字幕但路径为空时抛出异常', () {
      expect(
        () => service.exportAudioItem(
          displayName: 'Test',
          audioPath: audioFile.path,
          transcriptPath: null,
          includeAudio: false,
          includeTranscript: true,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('源文件不存在时抛出异常', () async {
      expect(
        () async => service.exportAudioItem(
          displayName: 'Test',
          audioPath: '/nonexistent/audio.mp3',
          includeAudio: true,
          includeTranscript: false,
        ),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
