/// Kokoro 原生合成器抽象 + isolate worker 实现。
///
/// 把"跑 sherpa-onnx native 推理"这步抽象为可注入接口，使 [KokoroTtsEngine]
/// 的业务逻辑（sid 解析、文件命名、降级）可纯单测；真实 FFI 推理放常驻 worker
/// isolate（同 `sherpa_onnx_engine.dart` 的 `_AsrWorker` 模式），不阻塞主线程。
///
/// `OfflineTts`（FFI 指针）只能在创建它的 isolate 内使用，故 `generate` +
/// `writeWave` 都在 worker 内执行，回传采样率。固定 `provider='cpu'`（可靠、
/// 规避 NNAPI 崩溃路径，详见 CLAUDE.md §7.4）。
library;

import 'dart:isolate';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../app_logger.dart';
import 'kokoro_model_manager.dart' show KokoroModelPaths;

/// Kokoro 原生合成器接口。
abstract interface class KokoroNativeSynthesizer {
  /// 加载模型（耗时数秒，幂等由实现保证）。
  Future<void> init(KokoroModelPaths paths, {int numThreads});

  /// 合成 [text] 为 wav 写入 [outputPath]。
  ///
  /// 成功返回采样率；失败返回 null（不抛，交上层降级）。
  Future<int?> synthesize({
    required String text,
    required int sid,
    required double speed,
    required String outputPath,
  });

  /// 释放模型与 isolate。
  Future<void> dispose();
}

/// 常驻 worker isolate 实现。
class IsolateKokoroSynthesizer implements KokoroNativeSynthesizer {
  _KokoroWorker? _worker;

  @override
  Future<void> init(KokoroModelPaths paths, {int numThreads = 2}) async {
    if (_worker != null) return;
    AppLogger.log(
      'KokoroTts',
      '┌ init model=${paths.model} threads=$numThreads',
    );
    final sw = Stopwatch()..start();
    _worker = await _KokoroWorker.spawn(paths, numThreads);
    sw.stop();
    AppLogger.log(
      'KokoroTts',
      '└ init done elapsed=${sw.elapsedMilliseconds}ms',
    );
  }

  @override
  Future<int?> synthesize({
    required String text,
    required int sid,
    required double speed,
    required String outputPath,
  }) async {
    final worker = _worker;
    if (worker == null) {
      throw StateError('Kokoro synthesizer not initialized.');
    }
    return worker.synthesize(
      text: text,
      sid: sid,
      speed: speed,
      outputPath: outputPath,
    );
  }

  @override
  Future<void> dispose() async {
    await _worker?.dispose();
    _worker = null;
  }
}

// ---------------------------------------------------------------------------
// Worker isolate
// ---------------------------------------------------------------------------

class _KokoroWorker {
  final Isolate _isolate;
  final SendPort _commandPort;

  _KokoroWorker._(this._isolate, this._commandPort);

  static Future<_KokoroWorker> spawn(
    KokoroModelPaths paths,
    int numThreads,
  ) async {
    final initPort = ReceivePort();
    final isolate = await Isolate.spawn(
      _entryPoint,
      _InitPayload(
        sendPort: initPort.sendPort,
        paths: paths,
        numThreads: numThreads,
      ),
    );
    final response = await initPort.first;
    initPort.close();
    if (response is SendPort) {
      return _KokoroWorker._(isolate, response);
    }
    isolate.kill(priority: Isolate.immediate);
    throw StateError('Kokoro worker init failed: $response');
  }

  Future<int?> synthesize({
    required String text,
    required int sid,
    required double speed,
    required String outputPath,
  }) async {
    final replyPort = ReceivePort();
    _commandPort.send(
      _SynthRequest(
        text: text,
        sid: sid,
        speed: speed,
        outputPath: outputPath,
        replyPort: replyPort.sendPort,
      ),
    );
    final response = await replyPort.first;
    replyPort.close();
    if (response is _SynthResponse) {
      // worker 在各自 isolate 内计时（AppLogger 跨 isolate 不通，故计时随响应
      // 回传，由主 isolate 统一落日志，见 §7.4）。
      AppLogger.log(
        'KokoroTts',
        '⏱ generate=${response.generateMs}ms writeWave=${response.writeMs}ms',
      );
      return response.sampleRate;
    }
    // 失败：worker 回传错误字符串，记录后返回 null（上层降级）。
    AppLogger.log('KokoroTts', '✗ synthesize failed: $response');
    return null;
  }

  Future<void> dispose() async {
    final replyPort = ReceivePort();
    _commandPort.send(_DisposeRequest(replyPort.sendPort));
    await replyPort.first;
    replyPort.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

class _InitPayload {
  final SendPort sendPort;
  final KokoroModelPaths paths;
  final int numThreads;
  const _InitPayload({
    required this.sendPort,
    required this.paths,
    required this.numThreads,
  });
}

class _SynthRequest {
  final String text;
  final int sid;
  final double speed;
  final String outputPath;
  final SendPort replyPort;
  const _SynthRequest({
    required this.text,
    required this.sid,
    required this.speed,
    required this.outputPath,
    required this.replyPort,
  });
}

class _SynthResponse {
  final int sampleRate;

  /// 纯推理（`OfflineTts.generate`）耗时，毫秒。
  final int generateMs;

  /// 写盘（`writeWave`）耗时，毫秒。
  final int writeMs;
  const _SynthResponse(this.sampleRate, this.generateMs, this.writeMs);
}

class _DisposeRequest {
  final SendPort replyPort;
  const _DisposeRequest(this.replyPort);
}

/// Worker isolate 入口：创建 OfflineTts，循环处理合成请求。
void _entryPoint(_InitPayload init) {
  sherpa.OfflineTts? tts;
  try {
    sherpa.initBindings();
    tts = sherpa.OfflineTts(
      sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: init.paths.model,
            voices: init.paths.voices,
            tokens: init.paths.tokens,
            dataDir: init.paths.dataDir,
            // Kokoro v1.0 是多语言模型（model version 2）：sherpa-onnx 1.13.8 的
            // native 层必须拿到 lexicon 或 lang，否则直接 abort 整个进程（无
            // Dart 异常）。本项目只合成英文，固定 en-us 音素，与 v0.19 的行为一致。
            lang: 'en-us',
          ),
          numThreads: init.numThreads,
          provider: 'cpu',
          debug: false,
        ),
      ),
    );

    final commandPort = ReceivePort();
    init.sendPort.send(commandPort.sendPort);

    commandPort.listen((message) {
      if (message is _SynthRequest) {
        try {
          final swGen = Stopwatch()..start();
          final audio = tts!.generate(
            text: message.text,
            sid: message.sid,
            speed: message.speed,
          );
          swGen.stop();
          final swWrite = Stopwatch()..start();
          final ok = sherpa.writeWave(
            filename: message.outputPath,
            samples: audio.samples,
            sampleRate: audio.sampleRate,
          );
          swWrite.stop();
          if (ok) {
            message.replyPort.send(
              _SynthResponse(
                audio.sampleRate,
                swGen.elapsedMilliseconds,
                swWrite.elapsedMilliseconds,
              ),
            );
          } else {
            message.replyPort.send('writeWave failed');
          }
        } catch (e) {
          message.replyPort.send('generate failed: $e');
        }
      } else if (message is _DisposeRequest) {
        tts?.free();
        message.replyPort.send(null);
        commandPort.close();
      }
    });
  } catch (e) {
    tts?.free();
    init.sendPort.send('Init failed: $e');
  }
}
