import 'dart:io';

import 'package:loop_back/features/audio_import/audio_transcode_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('AudioTranscodeService', () {
    testWidgets(
      'transcodes short silent common audio formats to readable m4a',
      (_) async {
        final fixtures = [
          'silence.wav',
          'silence.mp3',
          'silence_cover.mp3',
          'silence.m4a',
          'silence.aac',
          'silence.flac',
        ];
        final tempDir = await Directory.systemTemp.createTemp(
          'audio-transcode-fixtures-',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final service = AudioTranscodeService();
        for (final fixtureName in fixtures) {
          final ext = p.extension(fixtureName).replaceFirst('.', '');
          final inputFile = File(p.join(tempDir.path, 'input', fixtureName));
          await inputFile.parent.create(recursive: true);
          final fixtureData = await rootBundle.load(
            'test/fixtures/audio_transcode/$fixtureName',
          );
          await inputFile.writeAsBytes(
            fixtureData.buffer.asUint8List(
              fixtureData.offsetInBytes,
              fixtureData.lengthInBytes,
            ),
          );

          final outputFile = File(
            p.join(tempDir.path, 'output', '$fixtureName.m4a'),
          );
          final ok = await service
              .transcodeToFile(source: inputFile, output: outputFile)
              .timeout(const Duration(seconds: 10));

          expect(ok, isTrue, reason: 'format .$ext');
          expect(await outputFile.exists(), isTrue, reason: 'format .$ext');
          // 新 API 不删除源文件，源应保留。
          expect(await inputFile.exists(), isTrue, reason: 'format .$ext');
          expect(
            await outputFile.length(),
            greaterThan(0),
            reason: 'format .$ext',
          );

          final duration = await _readDuration(outputFile.path);
          expect(duration, isNotNull, reason: 'format .$ext');
          expect(
            duration!.inMilliseconds,
            greaterThan(400),
            reason: 'format .$ext',
          );
        }
      },
    );
  });
}

Future<Duration?> _readDuration(String path) async {
  final player = AudioPlayer();
  try {
    return await player.setFilePath(path);
  } finally {
    await player.dispose();
  }
}
