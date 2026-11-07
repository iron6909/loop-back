/// 在线文件转写客户端：OpenAI 兼容的 multipart `/audio/transcriptions`。
///
/// 与文字 AI 的 `ProviderHttpClient` 刻意隔离：不复用聊天请求体、SSE、权益门控，
/// 也不重试。这里只有用户配置的语音服务地址、语音 Key 与所选模型；响应必须经过
/// 严格校验，模型目录存在或文字聊天成功都不能代替这里的结论。输出结构与错误
/// 分类供后续跟读、复述与字幕切片复用。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'speech_config.dart';

/// 允许的越界舍入容差：模型按 10 ms 取整，不能因此把合法片段判成越界，
/// 也不能把明显越界修正为成功。
const speechTimestampToleranceSeconds = 0.25;

/// 在线转写失败的分类；界面据此给出可操作提示。
enum SpeechTranscriptionErrorKind {
  /// 400/422：供应商不接受这次请求的参数。
  invalidRequest,

  /// 400/422 且正文指向输出格式或时间戳参数不被支持。
  unsupportedCapability,

  /// 401：Key 无效或未授权。
  unauthorized,

  /// 402：账户余额或套餐不足。
  insufficientBalance,

  /// 404：服务地址或模型不存在。
  notFound,

  /// 413：上传音频超过服务限制。
  payloadTooLarge,

  /// 429：限流或额度耗尽。
  rateLimited,

  /// 5xx：服务异常；不自动重试，避免重复计费。
  serverError,

  /// 连接、发送或接收超时。
  timeout,

  /// 用户取消。
  cancelled,

  /// 其他网络错误。
  network,

  /// 2xx 但正文既不是文本也不是对象。
  invalidResponse,

  /// 2xx 但没有可用文本。
  emptyResult,
}

/// 一次在线转写失败。[toString] 只含分类与状态码，不含请求头、Key 或正文。
class SpeechTranscriptionException implements Exception {
  const SpeechTranscriptionException(this.kind, {this.statusCode});

  final SpeechTranscriptionErrorKind kind;
  final int? statusCode;

  @override
  String toString() =>
      'SpeechTranscriptionException(${kind.name}'
      '${statusCode == null ? '' : ', status=$statusCode'})';
}

/// 输出格式：文本用途用 [json]，字幕验证用 [verboseJson] 取片段时间戳。
enum SpeechResponseFormat {
  json('json'),
  verboseJson('verbose_json');

  const SpeechResponseFormat(this.wireName);

  /// 请求参数里使用的字面值。
  final String wireName;
}

/// 一个通过校验的片段时间戳。
class SpeechTranscriptSegment {
  const SpeechTranscriptSegment({
    required this.start,
    required this.end,
    required this.text,
  });

  final double start;
  final double end;
  final String text;
}

/// 一个通过校验的词时间戳。
class SpeechTranscriptWord {
  const SpeechTranscriptWord({
    required this.word,
    required this.start,
    required this.end,
  });

  final String word;
  final double start;
  final double end;
}

/// 一次转写的结果。
///
/// [segments] 与 [words] 只包含通过校验的条目；[segmentsValid] / [wordsValid]
/// 是「至少一条且全部合法」的结论，只有它为真才算具备字幕/词时间戳能力。
class SpeechTranscriptionResult {
  const SpeechTranscriptionResult({
    required this.text,
    this.segments = const [],
    this.words = const [],
    this.segmentsValid = false,
    this.wordsValid = false,
    this.reportedCost,
  });

  /// 已去掉首尾空白的最终文本；空文本已在客户端按失败处理。
  final String text;

  final List<SpeechTranscriptSegment> segments;
  final List<SpeechTranscriptWord> words;

  /// 有片段且全部有限、有序、起止合法并落在音频范围内。
  final bool segmentsValid;

  /// 请求了词时间戳参数且有词全部通过同样的校验。
  final bool wordsValid;

  /// 供应商报告的本次费用；没有给出时为 null，界面显示为未知，不能当作免费。
  final double? reportedCost;
}

/// 专用文件转写客户端；[dio] 供测试注入假 adapter，生产使用真实网络。
class SpeechTranscriptionClient {
  SpeechTranscriptionClient({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = const Duration(seconds: 15)
      ..sendTimeout = const Duration(seconds: 60)
      ..receiveTimeout = const Duration(seconds: 120)
      ..followRedirects = false
      ..headers.clear();
  }

  final Dio _dio;

  /// 发送一次转写请求；不重试、不换供应商、不自动变换参数。
  ///
  /// [audioDuration] 是本次上传音频的真实时长，用于校验供应商返回的时间戳是否
  /// 落在音频范围内；供应商自己报告的 `duration` 优先。
  Future<SpeechTranscriptionResult> transcribe({
    required SpeechConfig config,
    required String apiKey,
    required String modelId,
    required Uint8List audio,
    required String fileName,
    required Duration audioDuration,
    SpeechResponseFormat format = SpeechResponseFormat.verboseJson,
    bool requestWordTimestamps = false,
    String fileContentType = 'audio/wav',
    CancelToken? cancelToken,
  }) async {
    if (modelId.trim().isEmpty) {
      throw const SpeechTranscriptionException(
        SpeechTranscriptionErrorKind.invalidRequest,
      );
    }
    if (apiKey.trim().isEmpty || RegExp(r'[\r\n]').hasMatch(apiKey)) {
      throw const SpeechTranscriptionException(
        SpeechTranscriptionErrorKind.unauthorized,
      );
    }
    final form = FormData();
    form.fields
      ..add(MapEntry('model', modelId.trim()))
      // 首期只面向英语材料，语言固定，不自动识别。
      ..add(MapEntry('language', 'en'))
      ..add(MapEntry('response_format', format.wireName));
    // 词时间戳参数只对已确认支持的配置请求：供应商不支持时整个请求会被拒绝。
    if (requestWordTimestamps) {
      form.fields.add(const MapEntry('timestamp_granularities[]', 'word'));
    }
    form.files.add(
      MapEntry(
        'file',
        MultipartFile.fromBytes(
          audio,
          filename: fileName,
          contentType: DioMediaType.parse(fileContentType),
        ),
      ),
    );
    try {
      final response = await _dio.post<Object?>(
        config.transcriptionUrl,
        data: form,
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
          speechTranscriptionErrorKindFor(
            status,
            body: _bodyText(response.data),
          ),
          statusCode: status,
        );
      }
      return _parse(
        response.data,
        audioDuration: audioDuration,
        requestWordTimestamps: requestWordTimestamps,
      );
    } on DioException catch (error) {
      throw SpeechTranscriptionException(speechTranscriptionErrorKindForDio(error));
    }
  }

  /// 2xx 正文：JSON 对象取结构，纯文本正文按文本处理。
  SpeechTranscriptionResult _parse(
    Object? data, {
    required Duration audioDuration,
    required bool requestWordTimestamps,
  }) {
    final map = _asMap(data);
    final rawText = map?['text'] ?? _asText(data);
    if (rawText is! String || rawText.trim().isEmpty) {
      throw const SpeechTranscriptionException(
        SpeechTranscriptionErrorKind.emptyResult,
      );
    }
    final boundSeconds = _positiveSeconds(map?['duration']) ??
        audioDuration.inMilliseconds / 1000;
    final segments = _parseSegments(map?['segments'], boundSeconds);
    final words = _parseWords(map?['words'], boundSeconds);
    return SpeechTranscriptionResult(
      text: rawText.trim(),
      segments: segments.items,
      words: words.items,
      segmentsValid: segments.allValid,
      // 没有请求词参数时，响应里即使带词也不能当作已确认能力。
      wordsValid: requestWordTimestamps && words.allValid,
      reportedCost: _reportedCost(map?['usage']),
    );
  }

  /// 正文对象；数组或标量不是对象，若同时没有可用文本则属于无效响应。
  Map<String, Object?>? _asMap(Object? data) {
    if (data is Map<String, Object?>) return data;
    if (data is Map) {
      return {
        for (final entry in data.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
    }
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        return decoded is Map ? _asMap(decoded) : null;
      } on FormatException {
        return null;
      }
    }
    if (data == null || (data is List)) {
      throw const SpeechTranscriptionException(
        SpeechTranscriptionErrorKind.invalidResponse,
      );
    }
    return null;
  }

  String? _asText(Object? data) => data is String ? data : null;

  _ParsedTimestamps<SpeechTranscriptSegment> _parseSegments(
    Object? raw,
    double boundSeconds,
  ) {
    if (raw is! List || raw.isEmpty) {
      return const _ParsedTimestamps(items: [], allValid: false);
    }
    final items = <SpeechTranscriptSegment>[];
    var allValid = true;
    for (final item in raw) {
      final parsed = _segmentFrom(item, boundSeconds);
      if (parsed == null || !_orderedAfter(items.isEmpty ? null : items.last.start, parsed.start)) {
        allValid = false;
        continue;
      }
      items.add(parsed);
    }
    return _ParsedTimestamps(items: items, allValid: allValid && items.isNotEmpty);
  }

  SpeechTranscriptSegment? _segmentFrom(Object? item, double boundSeconds) {
    if (item is! Map) return null;
    final text = item['text'];
    final start = _positiveSeconds(item['start'], allowZero: true);
    final end = _positiveSeconds(item['end'], allowZero: true);
    if (text is! String || start == null || end == null) return null;
    if (!_withinRange(start, end, boundSeconds)) return null;
    return SpeechTranscriptSegment(start: start, end: end, text: text);
  }

  _ParsedTimestamps<SpeechTranscriptWord> _parseWords(
    Object? raw,
    double boundSeconds,
  ) {
    if (raw is! List || raw.isEmpty) {
      return const _ParsedTimestamps(items: [], allValid: false);
    }
    final items = <SpeechTranscriptWord>[];
    var allValid = true;
    for (final item in raw) {
      if (item is! Map) {
        allValid = false;
        continue;
      }
      final word = item['word'];
      final start = _positiveSeconds(item['start'], allowZero: true);
      final end = _positiveSeconds(item['end'], allowZero: true);
      if (word is! String ||
          word.trim().isEmpty ||
          start == null ||
          end == null ||
          !_withinRange(start, end, boundSeconds) ||
          !_orderedAfter(items.isEmpty ? null : items.last.start, start)) {
        allValid = false;
        continue;
      }
      items.add(SpeechTranscriptWord(word: word, start: start, end: end));
    }
    return _ParsedTimestamps(items: items, allValid: allValid && items.isNotEmpty);
  }

  /// 起止必须有限、非负、起点不晚于终点，并落在音频范围内（含舍入容差）。
  bool _withinRange(double start, double end, double boundSeconds) =>
      start >= 0 &&
      start <= end &&
      end <= boundSeconds + speechTimestampToleranceSeconds;

  /// 片段按时间顺序出现；同一时刻的相邻片段允许相等。
  bool _orderedAfter(double? previousStart, double start) =>
      previousStart == null || start >= previousStart;

  /// 有限且非负的秒数；`allowZero` 为假时零也被拒绝（用于音频时长）。
  double? _positiveSeconds(Object? value, {bool allowZero = false}) {
    if (value is! num) return null;
    final seconds = value.toDouble();
    if (!seconds.isFinite) return null;
    if (allowZero ? seconds < 0 : seconds <= 0) return null;
    return seconds;
  }

  double? _reportedCost(Object? usage) {
    if (usage is! Map) return null;
    final cost = usage['cost'];
    if (cost is! num) return null;
    final value = cost.toDouble();
    return value.isFinite && value >= 0 ? value : null;
  }
}

/// 把非 2xx 状态码映射成领域分类。
///
/// 400/422 只在错误体明确指向输出格式或时间戳参数时算能力不支持；不替供应商
/// 猜测，也不因为一句模糊的失败就宣称该模型不能做字幕。
SpeechTranscriptionErrorKind speechTranscriptionErrorKindFor(
  int status, {
  String? body,
}) {
  switch (status) {
    case 400 || 422:
      return _looksLikeUnsupportedCapability(body)
          ? SpeechTranscriptionErrorKind.unsupportedCapability
          : SpeechTranscriptionErrorKind.invalidRequest;
    case 401:
      return SpeechTranscriptionErrorKind.unauthorized;
    case 402:
      return SpeechTranscriptionErrorKind.insufficientBalance;
    case 404:
      return SpeechTranscriptionErrorKind.notFound;
    case 413:
      return SpeechTranscriptionErrorKind.payloadTooLarge;
    case 429:
      return SpeechTranscriptionErrorKind.rateLimited;
    case >= 500:
      return SpeechTranscriptionErrorKind.serverError;
    default:
      return SpeechTranscriptionErrorKind.network;
  }
}

/// 网络层异常的分类；取消与超时不可混为普通网络错误。
SpeechTranscriptionErrorKind speechTranscriptionErrorKindForDio(
  DioException error,
) => switch (error.type) {
  DioExceptionType.cancel => SpeechTranscriptionErrorKind.cancelled,
  DioExceptionType.connectionTimeout ||
  DioExceptionType.sendTimeout ||
  DioExceptionType.receiveTimeout => SpeechTranscriptionErrorKind.timeout,
  _ => SpeechTranscriptionErrorKind.network,
};

/// 只保留前 2 KB 的错误体文本，供能力不支持的判定使用；不写入日志。
String? _bodyText(Object? data) {
  final text = switch (data) {
    String() => data,
    Map() => jsonEncode(data),
    _ => null,
  };
  if (text == null || text.isEmpty) return null;
  return text.length <= 2048 ? text : text.substring(0, 2048);
}

/// 错误体是否明确指向输出格式或时间戳参数不被支持。
bool _looksLikeUnsupportedCapability(String? body) {
  final text = (body ?? '').toLowerCase();
  return text.contains('response_format') ||
      text.contains('verbose_json') ||
      text.contains('timestamp_granularities') ||
      text.contains('timestamps');
}

/// 校验后的时间戳列表与「是否全部合法」的结论。
class _ParsedTimestamps<T> {
  const _ParsedTimestamps({required this.items, required this.allValid});

  final List<T> items;
  final bool allValid;
}
