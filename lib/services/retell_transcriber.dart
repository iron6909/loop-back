/// 复述录音独立转写：只读原录音，临时 WAV 与引擎在同一生命周期内清理。
library;

import 'package:universal_io/io.dart';
import '../features/audio_import/audio_transcode_service.dart';
import 'app_logger.dart';
import 'asr/offline_asr_engine.dart';

class RetellTranscriber {
  RetellTranscriber({required this.engineFactory, required this.configuration,
    required this.transcode});
  final OfflineAsrEngine Function() engineFactory;
  final Future<AsrModelConfig> Function() configuration;
  final AudioTranscodeService transcode;

  /// 不传 VAD 模型路径，避开部分 Android 设备的 Silero native 崩溃面。
  Future<String?> transcribe(String recordingPath) async {
    final directory = await Directory.systemTemp.createTemp('retell_review_');
    final wav = File('${directory.path}/input.wav');
    OfflineAsrEngine? engine;
    try {
      if (!await transcode.transcodeToPcmWav16k(
        source: File(recordingPath), output: wav)) {
        return null;
      }
      engine = engineFactory();
      final config = await configuration();
      await engine.initialize(AsrModelConfig(model: config.model,
        modelDir: config.modelDir, numThreads: config.numThreads));
      final result = await engine.transcribe(wav.path);
      return result.text.trim().isEmpty ? null : result.text.trim();
    } finally {
      await engine?.dispose();
      try { await directory.delete(recursive: true); }
      catch (error) { AppLogger.log('RetellReview', '临时转写文件清理失败: ${error.runtimeType}'); }
    }
  }
}
