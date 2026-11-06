/// 复述独立转写：只读原录音、无上传大小合同、VAD 不传给原生引擎。
library;

import 'dart:io';
import 'package:echo_loop/features/audio_import/audio_transcode_service.dart';
import 'package:echo_loop/services/asr/offline_asr_engine.dart';
import 'package:echo_loop/services/retell_transcriber.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Engine extends Mock implements OfflineAsrEngine {}

class _Transcode extends AudioTranscodeService {
  String? temporaryPath;
  @override
  Future<bool> transcodeToPcmWav16k({
    required File source,
    required File output,
  }) async {
    temporaryPath = output.path;
    await output.writeAsBytes([0, 0]);
    return true;
  }
}

void main() {
  final configuration = AsrModelConfig(
    model: const AsrModelInfo(
      id: 'test',
      displayName: 'test',
      type: AsrModelType.whisper,
    ),
    modelDir: '/models',
    vadModelPath: '/models/silero.onnx',
  );
  setUpAll(() => registerFallbackValue(configuration));

  for (final fail in [false, true]) {
    test('转写${fail ? '失败' : '成功'}仍释放引擎与临时文件，保留超过 2MB 的原录音', () async {
      final directory = await Directory.systemTemp.createTemp('retell_check_');
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/source.m4a');
      await source.writeAsBytes(List.filled(2 * 1024 * 1024 + 1, 7));
      final engine = _Engine();
      final transcode = _Transcode();
      AsrModelConfig? received;
      when(() => engine.initialize(any())).thenAnswer((call) async {
        if (call.positionalArguments.first case final AsrModelConfig config) {
          received = config;
        }
      });
      when(() => engine.dispose()).thenAnswer((_) async {});
      when(() => engine.transcribe(any())).thenAnswer((_) async {
        if (fail) throw StateError('recognition failed');
        return const AsrResult(
          text: ' My retelling ',
          inferenceTime: Duration.zero,
        );
      });
      final service = RetellTranscriber(
        engineFactory: () => engine,
        configuration: () async => configuration,
        transcode: transcode,
      );
      if (fail) {
        await expectLater(service.transcribe(source.path), throwsStateError);
      } else {
        expect(await service.transcribe(source.path), 'My retelling');
      }
      expect(received?.vadModelPath, isNull);
      verify(() => engine.dispose()).called(1);
      expect(File(transcode.temporaryPath ?? '').existsSync(), isFalse);
      expect(await source.length(), 2 * 1024 * 1024 + 1);
      expect((await source.readAsBytes()).every((byte) => byte == 7), isTrue);
    });
  }
}
