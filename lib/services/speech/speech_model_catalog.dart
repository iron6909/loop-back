/// OpenRouter 专用转写模型目录。
///
/// 目录只证明模型存在，不能代替实际能力验证；刷新失败不阻止手填模型 ID，自定义
/// 服务不强制提供 `/models`，也不会把语音 Key 发给配置以外的主机。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import 'speech_config.dart';
import 'speech_transcription_client.dart';

/// 读取服务端提供的转写模型 ID 列表。
class SpeechModelCatalogClient {
  SpeechModelCatalogClient({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = const Duration(seconds: 15)
      ..receiveTimeout = const Duration(seconds: 30)
      ..followRedirects = false
      ..headers.clear();
  }

  final Dio _dio;

  /// 拉取 OpenRouter 的专用 STT 目录。
  ///
  /// 只有预设本身提供目录接口；其他服务一律走手填，不向未知地址探测。
  Future<List<String>> fetchTranscriptionModels({
    required SpeechConfig config,
    required String apiKey,
    CancelToken? cancelToken,
  }) async {
    if (config.kind != SpeechProviderKind.openrouter) {
      throw ArgumentError('自定义服务不提供转写模型目录');
    }
    if (apiKey.trim().isEmpty || RegExp(r'[\r\n]').hasMatch(apiKey)) {
      throw const SpeechTranscriptionException(
        SpeechTranscriptionErrorKind.unauthorized,
      );
    }
    final uri = Uri.parse(
      '${config.baseRoot}/models?output_modalities=transcription',
    );
    // 地址来自用户配置，Key 只发往该地址的 Origin。
    if (uri.origin != Uri.parse(config.baseUrl).origin) {
      throw ArgumentError('模型目录地址与服务地址不一致');
    }
    try {
      final response = await _dio.get<Object?>(
        uri.toString(),
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Accept': 'application/json',
          },
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        throw SpeechTranscriptionException(
          speechTranscriptionErrorKindFor(status),
          statusCode: status,
        );
      }
      return _modelIds(response.data);
    } on DioException catch (error) {
      throw SpeechTranscriptionException(
        speechTranscriptionErrorKindForDio(error),
      );
    }
  }

  /// 目录响应是 `{"data": [{"id": ...}, ...]}`；缺失或为空返回空列表。
  List<String> _modelIds(Object? data) {
    final decoded = switch (data) {
      Map<String, Object?>() => data,
      String() => _tryDecodeObject(data),
      _ => null,
    };
    if (decoded == null) {
      throw const SpeechTranscriptionException(
        SpeechTranscriptionErrorKind.invalidResponse,
      );
    }
    final data_ = decoded['data'];
    if (data_ is! List) return const [];
    final ids = <String>[];
    for (final item in data_) {
      if (item is Map) {
        final id = item['id'];
        if (id is String && id.trim().isNotEmpty && !ids.contains(id.trim())) {
          ids.add(id.trim());
        }
      }
    }
    return ids;
  }

  Map<String, Object?>? _tryDecodeObject(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? {for (final entry in decoded.entries) '${entry.key}': entry.value} : null;
    } on FormatException {
      return null;
    }
  }
}
