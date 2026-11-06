/// 六项结构化功能的统一客户端
///
/// 一条流水线：组提示词 → 发请求（按能力选输出模式）→ 严格校验 → 命中写缓存 →
/// 产出**单个** `isFinal=true` 帧。失败一律不写缓存，也不靠回落把坏结果变成成功
/// （回落只解决「端点不认 `response_format`」）。
///
/// 校验函数由调用方注入：各功能结果类型不同，注入匹配的强类型校验器即可，既避免
/// `Object` 返回值加类型强转，也避免为六种结果各写一层包装类。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../utils/text_normalize.dart';

import 'output_mode.dart';
import 'provider_cache_key.dart';
import 'provider_config.dart';
import 'provider_http_client.dart';
import 'structured_prompts.dart';
import 'structured_result_validator.dart';

/// 一次结构化请求。
class StructuredAiRequest {
  const StructuredAiRequest({
    required this.feature,
    required this.text,
    this.previousText,
    this.nextText,
    this.targetLanguage,
  });

  final StructuredFeature feature;

  /// 待处理原文；意群功能同时作为守恒校验的基准。
  final String text;

  /// 上一句，仅作上下文。
  final String? previousText;

  /// 下一句，仅作上下文。
  final String? nextText;

  /// 目标语言（BCP 47）。
  final String? targetLanguage;
}

/// 单个终帧。
class StructuredFrame<T> {
  const StructuredFrame(this.value, {required this.isFinal});

  final T value;
  final bool isFinal;
}

/// 校验失败或输出被截断。
class StructuredValidationException implements Exception {
  const StructuredValidationException(this.reason);

  final ValidationFailureReason reason;

  @override
  String toString() => 'StructuredValidationException(${reason.name})';
}

/// 缓存写入回调；签名与 `SentenceAiCacheDao.upsert` 对齐。
typedef StructuredCacheReader =
    Future<String?> Function(String textHash, String type);

typedef StructuredCacheWriter =
    Future<void> Function({
      required String type,
      required String textHash,
      required String payload,
    });

/// 六功能共用的结构化客户端。
class StructuredAiClient {
  StructuredAiClient({
    required ProviderHttpClient http,
    required ProviderConfig config,
    StructuredCacheWriter? writeCache,
    StructuredCacheReader? readCache,
  }) : _http = http,
       _config = config,
       _writeCache = writeCache,
       _readCache = readCache;

  final ProviderHttpClient _http;
  final ProviderConfig _config;
  final StructuredCacheWriter? _writeCache;
  final StructuredCacheReader? _readCache;
  final Map<String, String> _memory = {};
  final Set<CancelToken> _active = {};

  int _generation = 0;

  /// 作废在途请求的结果：配置切换、页面关闭时调用。
  void invalidate() {
    _generation++;
    for (final token in _active.toList()) {
      token.cancel('provider configuration changed');
    }
    _active.clear();
    _memory.clear();
  }

  /// 释放底层连接。
  void dispose() {
    invalidate();
    _http.dispose();
  }

  /// 发起一次结构化调用，最多产出一帧。
  Stream<StructuredFrame<T>> stream<T>({
    required StructuredAiRequest request,
    required ValidationOutcome<T> Function(Object? decoded) validate,
    CancelToken? cancelToken,
  }) async* {
    final generation = _generation;
    final token = cancelToken ?? CancelToken();
    _active.add(token);
    try {
      final cached = await readCached(request, validate);
      if (generation != _generation || token.isCancelled) return;
      if (cached != null) {
        yield StructuredFrame(cached, isFinal: true);
        return;
      }
      yield* _generate(request, validate, token, generation);
    } finally {
      _active.remove(token);
    }
  }

  Stream<StructuredFrame<T>> _generate<T>(
    StructuredAiRequest request,
    ValidationOutcome<T> Function(Object?) validate,
    CancelToken token,
    int generation,
  ) async* {
    // DeepSeek 的 response_format 仅支持 JSON 对象，不能发送严格 Schema。
    var mode = _config.kind == ProviderKind.deepseek
        ? OutputMode.jsonObject
        : OutputMode.jsonSchema;
    while (true) {
      final Map<String, dynamic> envelope;
      try {
        envelope = await _http.postChatCompletions(
          _body(request, mode),
          cancelToken: token,
        );
      } on ProviderHttpException catch (error) {
        if (generation != _generation || token.isCancelled) return;
        // 只有「明确不支持当前输出模式」才允许回落一次。
        final next =
            indicatesUnsupportedOutputMode(
              statusCode: error.statusCode,
              errorBody: error.body,
            )
            ? fallbackOutputMode(
                current: mode,
                failure: OutputFailureKind.unsupportedOutputMode,
              )
            : null;
        if (next == null) rethrow;
        mode = next;
        continue;
      }

      // 配置已切换或页面已关闭：结果作废，不写缓存也不产出。
      if (generation != _generation || token.isCancelled) return;

      final content = _content(envelope);
      final decoded = _decode(content);
      final outcome = validate(decoded);

      switch (outcome) {
        case ValidationSuccess<T>(:final value):
          if (generation != _generation || token.isCancelled) return;
          await _cache(request, content);
          if (generation != _generation || token.isCancelled) return;
          yield StructuredFrame(value, isFinal: true);
          return;
        case ValidationFailure<T>(:final reason):
          throw StructuredValidationException(reason);
      }
    }
  }

  /// 取正文；`finish_reason=length` 说明输出被预算截断，直接判失败。
  String _content(Map<String, dynamic> envelope) {
    final choices = envelope['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const StructuredValidationException(
        ValidationFailureReason.emptyBody,
      );
    }
    final choice = choices.first;
    if (choice is! Map<String, dynamic>) {
      throw const StructuredValidationException(
        ValidationFailureReason.emptyBody,
      );
    }
    if (choice['finish_reason'] == 'length') {
      throw const StructuredValidationException(
        ValidationFailureReason.truncated,
      );
    }
    final message = choice['message'];
    final content = message is Map<String, dynamic> ? message['content'] : null;
    if (content is! String || content.trim().isEmpty) {
      throw const StructuredValidationException(
        ValidationFailureReason.emptyBody,
      );
    }
    return content;
  }

  /// 正文解析失败时把原串交给校验器，由它判 `notJsonObject`。
  Object? _decode(String content) {
    try {
      return jsonDecode(content);
    } on FormatException {
      return content;
    }
  }

  /// 只在成功且 generation 仍有效时写缓存；失败路径从不调用。
  Future<void> _cache(StructuredAiRequest request, String payload) async {
    final type = typeFor(request);
    final hash = hashFor(request);
    await _writeCache?.call(type: type, textHash: hash, payload: payload);
    _memory['$type:$hash'] = payload;
  }

  /// 读取缓存也严格校验；旧行与损坏行保留在库中，不删除。
  Future<T?> readCached<T>(
    StructuredAiRequest request,
    ValidationOutcome<T> Function(Object?) validate,
  ) async {
    final type = typeFor(request);
    final hash = hashFor(request);
    final raw = _memory['$type:$hash'] ?? await _readCache?.call(hash, type);
    if (raw == null) return null;
    final result = validate(_decode(raw));
    if (result case ValidationSuccess<T>(:final value)) return value;
    return null;
  }

  String typeFor(StructuredAiRequest request) => cacheType(
    feature: _cacheName(request.feature),
    fingerprint: configFingerprint(
      baseUrl: _config.baseUrl,
      model: _config.model,
      promptVersion: _config.promptVersion,
    ),
    targetLanguage: request.targetLanguage,
  );

  /// 沿用翻译上下文哈希与既有词典归一规则。
  String hashFor(StructuredAiRequest request) => switch (request.feature) {
    StructuredFeature.translation => translationContextHash(
      request.text,
      previous: request.previousText,
      next: request.nextText,
    ),
    StructuredFeature.word || StructuredFeature.phrase => hashText(
      '${normalizeWord(request.text)}|${request.targetLanguage ?? 'zh-CN'}',
    ),
    // 同一原文的每次复述都可能不同，缓存身份必须同时包含实际转写。
    StructuredFeature.retell => hashText(
      jsonEncode([request.text, request.previousText]),
    ),
    _ => hashText(request.text),
  };

  void clearMemoryCache() => _memory.clear();

  /// 沿用既有缓存类型前缀，旧后端写入的行因此自然不再命中。
  String _cacheName(StructuredFeature feature) => switch (feature) {
    StructuredFeature.translation => 'translation_v2',
    StructuredFeature.analysis => 'analysis_v2',
    StructuredFeature.word || StructuredFeature.phrase => 'ai_dictionary_v2',
    StructuredFeature.senseGroups => 'sense_groups',
    StructuredFeature.retell => 'retell_review_v2',
  };

  Map<String, Object?> _body(StructuredAiRequest request, OutputMode mode) {
    final prompt = structuredPromptFor(request.feature);
    return {
      'model': _config.model,
      'messages': [
        {
          'role': 'system',
          // JSON 对象模式没有独立 Schema 参数，字段约束必须随指令发送。
          'content': mode == OutputMode.jsonObject
              ? '${prompt.system}\n输出结构定义：${jsonEncode(prompt.jsonSchema['json_schema'])}'
              : prompt.system,
        },
        {
          'role': 'user',
          'content': buildUserContent(
            feature: request.feature,
            text: request.text,
            previousText: request.previousText,
            nextText: request.nextText,
            targetLanguage: request.targetLanguage,
          ),
        },
      ],
      'max_tokens': 2048,
      'response_format': mode == OutputMode.jsonSchema
          ? prompt.jsonSchema
          : const {'type': 'json_object'},
      // DeepSeek 默认开启思考且计入输出预算，必须显式关闭。
      if (_config.kind == ProviderKind.deepseek)
        'thinking': const {'type': 'disabled'},
      // OpenRouter 只在模型真正支持这些参数时才路由到该模型。
      if (_config.kind == ProviderKind.openrouter)
        'provider': const {'require_parameters': true},
    };
  }
}
