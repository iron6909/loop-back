/// 原生音频解码桥接。
///
/// 为字幕自动校准提供平台侧解码后的单声道 PCM 数据。
/// 当前支持 iOS / macOS / Android（均走 `top.loop-back/audio_decode` MethodChannel），
/// 其他平台返回 null 或抛出受控异常，由上层决定是否降级回退。
library;

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 供静音检测使用的解码结果。
///
/// [samples] 为归一化到 [-1, 1] 的单声道 Float32 PCM。
class DecodedAudioData {
  final Float32List samples;
  final int sampleRate;

  const DecodedAudioData({required this.samples, required this.sampleRate});

  /// 从平台通道 payload 构造解码结果。
  ///
  /// 约定平台返回 little-endian 的 Float32 PCM 字节数组。
  factory DecodedAudioData.fromChannelPayload(Map<Object?, Object?> payload) {
    final rawBytes = payload['pcmBytes'];
    final rawSampleRate = payload['sampleRate'];

    if (rawBytes is! Uint8List) {
      throw const NativeAudioDecoderException(
        'invalidResult',
        'Platform returned unexpected pcmBytes type',
      );
    }
    if (rawSampleRate is! int || rawSampleRate <= 0) {
      throw const NativeAudioDecoderException(
        'invalidResult',
        'Platform returned invalid sampleRate',
      );
    }

    final byteData = ByteData.sublistView(rawBytes);
    final sampleCount = rawBytes.lengthInBytes ~/ Float32List.bytesPerElement;
    final samples = Float32List(sampleCount);
    for (var i = 0; i < sampleCount; i++) {
      samples[i] = byteData.getFloat32(
        i * Float32List.bytesPerElement,
        Endian.little,
      );
    }

    return DecodedAudioData(samples: samples, sampleRate: rawSampleRate);
  }
}

/// 原生音频解码抽象。
abstract class NativeAudioDecoder {
  /// 当前平台是否具备原生解码能力。
  bool get isSupported;

  /// 解码本地音频文件。
  ///
  /// 返回 null 表示平台显式跳过解码（例如不支持或无法处理该文件）。
  Future<DecodedAudioData?> decode(String audioPath);
}

/// 平台桥接错误。
class NativeAudioDecoderException implements Exception {
  final String code;
  final String message;

  const NativeAudioDecoderException(this.code, this.message);

  @override
  String toString() => 'NativeAudioDecoderException($code, $message)';
}

/// 通过 MethodChannel 调用原生音频解码。
///
/// iOS / macOS 使用 AVFoundation，Android 使用 MediaExtractor + MediaCodec，
/// 均实现同一协议：`decode({audioPath}) -> {sampleRate, pcmBytes}`，其中
/// `pcmBytes` 为归一化 Float32 little-endian 单声道 PCM，采样率 1000 Hz。
class PlatformNativeAudioDecoder implements NativeAudioDecoder {
  const PlatformNativeAudioDecoder();

  static const MethodChannel _channel = MethodChannel(
    'top.loop-back/audio_decode',
  );

  @override
  bool get isSupported =>
      !kIsWeb && (Platform.isIOS || Platform.isMacOS || Platform.isAndroid);

  @override
  Future<DecodedAudioData?> decode(String audioPath) async {
    if (!isSupported) {
      return null;
    }

    try {
      final result = await _channel.invokeMethod<Object?>('decode', {
        'audioPath': audioPath,
      });
      if (result == null) {
        return null;
      }
      if (result is Map<Object?, Object?>) {
        return DecodedAudioData.fromChannelPayload(result);
      }
      throw const NativeAudioDecoderException(
        'invalidResult',
        'Platform returned unexpected result type',
      );
    } on MissingPluginException {
      throw const NativeAudioDecoderException(
        'notAvailable',
        'Native audio decode plugin is not registered on this platform',
      );
    } on PlatformException catch (error) {
      throw NativeAudioDecoderException(
        error.code,
        error.message ?? 'Unknown platform error',
      );
    }
  }
}

/// 原生音频解码 Provider。
final nativeAudioDecoderProvider = Provider<NativeAudioDecoder>(
  (_) => const PlatformNativeAudioDecoder(),
);
