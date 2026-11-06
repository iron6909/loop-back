/// 六项 AI 能力的应用接口；请求、校验和缓存统一由供应商客户端负责。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/dictionary/dictionary_entry.dart';
import '../models/retell_review_evaluation.dart';
import '../providers/provider_configuration_provider.dart';
import 'provider/provider_config.dart';
import 'provider/provider_http_client.dart';
import 'provider/structured_ai_client.dart';
import 'provider/structured_prompts.dart';
import 'provider/structured_result_validator.dart';

export 'sentence_ai_frames.dart';
import 'sentence_ai_frames.dart';

/// 按调用时的配置取得客户端，避免把旧配置保存在页面里。
typedef StructuredClientResolver = Future<StructuredAiClient?> Function();

class SentenceAiApiClient {
  SentenceAiApiClient.provider({required StructuredClientResolver structuredClient})
    : _resolve = structuredClient;

  /// 测试与独立调用的注入入口；空 Key 仍会被 HTTP 层拒绝。
  SentenceAiApiClient.withDio(
    Dio dio, {
    ProviderConfig config = const ProviderConfig(
      kind: ProviderKind.custom,
      baseUrl: 'https://unconfigured.invalid/v1',
      model: 'unconfigured',
    ),
    String apiKey = '',
    void Function(String)? streamLogPrint,
  }) : _owned = StructuredAiClient(
         http: ProviderHttpClient(config: config, apiKey: apiKey, dio: dio),
         config: config,
       );

  StructuredClientResolver? _resolve;
  StructuredAiClient? _owned;

  /// 入口不再接收后端身份；旧调用签名中的 accessToken 仅待调用方清理。
  Future<StructuredAiClient> _client() async {
    final owned = _owned;
    if (owned != null) return owned;
    final client = await _resolve?.call();
    if (client == null) throw const ProviderNotConfiguredException();
    return client;
  }

  Stream<SentenceTranslationStreamFrame> translateStream(
    String text, {
    String accessToken = '',
    String? previousText,
    String? nextText,
    String? targetLanguage,
    CancelToken? cancelToken,
  }) async* {
    final client = await _client();
    yield* client.stream(
      request: StructuredAiRequest(
        feature: StructuredFeature.translation, text: text,
        previousText: previousText, nextText: nextText,
        targetLanguage: targetLanguage,
      ),
      validate: validateTranslation, cancelToken: cancelToken,
    ).map((f) => SentenceTranslationStreamFrame(
      translation: f.value, isFinal: f.isFinal,
    ));
  }

  Stream<SentenceAnalysisStreamFrame> analyzeStream(
    String text, {
    String accessToken = '',
    String? targetLanguage,
    CancelToken? cancelToken,
  }) async* {
    final client = await _client();
    yield* client.stream(
      request: StructuredAiRequest(feature: StructuredFeature.analysis,
        text: text, targetLanguage: targetLanguage),
      validate: validateAnalysis, cancelToken: cancelToken,
    ).map((f) => SentenceAnalysisStreamFrame(
      analysis: f.value, isFinal: f.isFinal,
    ));
  }

  Stream<AiDictionaryEntry> lookupWordStream(String word, {
    String accessToken = '', String? targetLanguage, CancelToken? cancelToken,
  }) => lookupWordStreamFrames(word, targetLanguage: targetLanguage,
    cancelToken: cancelToken).map((f) => f.entry);

  Stream<AiDictionaryEntry> lookupPhraseStream(String phrase, {
    String accessToken = '', String? targetLanguage, CancelToken? cancelToken,
  }) => lookupPhraseStreamFrames(phrase, targetLanguage: targetLanguage,
    cancelToken: cancelToken).map((f) => f.entry);

  Stream<AiDictionaryStreamFrame> lookupWordStreamFrames(String word, {
    String accessToken = '', String? targetLanguage, CancelToken? cancelToken,
  }) => _dictionary(StructuredFeature.word, word, validateWordEntry,
    targetLanguage, cancelToken);

  Stream<AiDictionaryStreamFrame> lookupPhraseStreamFrames(String phrase, {
    String accessToken = '', String? targetLanguage, CancelToken? cancelToken,
  }) => _dictionary(StructuredFeature.phrase, phrase, validatePhraseEntry,
    targetLanguage, cancelToken);

  Stream<AiDictionaryStreamFrame> _dictionary<T extends AiDictionaryEntry>(
    StructuredFeature feature, String text,
    ValidationOutcome<T> Function(Object?) validate,
    String? language, CancelToken? token,
  ) async* {
    final client = await _client();
    yield* client.stream(
      request: StructuredAiRequest(feature: feature, text: text,
        targetLanguage: language),
      validate: validate, cancelToken: token,
    ).map((f) => AiDictionaryStreamFrame(entry: f.value, isFinal: f.isFinal));
  }

  Stream<SenseGroupsStreamFrame> senseGroupsStream(String text, {
    String accessToken = '', CancelToken? cancelToken,
  }) async* {
    final client = await _client();
    yield* client.stream(
      request: StructuredAiRequest(feature: StructuredFeature.senseGroups, text: text),
      validate: (value) => validateSenseGroups(value, original: text),
      cancelToken: cancelToken,
    ).map((f) => SenseGroupsStreamFrame(result: f.value, isFinal: f.isFinal));
  }

  /// 复述只发送原文和本机转写，不上传录音。
  Stream<RetellReviewStreamFrame> evaluateTranscriptStream({
    required String transcript, required String originalText,
    required String targetLanguage, CancelToken? cancelToken,
  }) async* {
    final client = await _client();
    yield* client.stream(
      request: StructuredAiRequest(feature: StructuredFeature.retell,
        text: originalText, previousText: transcript, targetLanguage: targetLanguage),
      validate: (value) {
        final result = validateRetell(value);
        return switch (result) {
          ValidationFailure<RetellReviewEvaluation>(:final reason) => ValidationFailure<RetellReviewEvaluation>(reason),
          ValidationSuccess<RetellReviewEvaluation>(:final value) => ValidationSuccess(
            RetellReviewEvaluation(transcript: transcript, summary: value.summary,
              rating: value.rating, keyPoints: value.keyPoints,
              suggestion: value.suggestion, corrections: value.corrections)),
        };
      }, cancelToken: cancelToken,
    ).map((f) => RetellReviewStreamFrame(evaluation: f.value, isFinal: f.isFinal));
  }

  /// 只读当前配置缓存；预热不会发起推理。
  Future<T?> readCached<T>(StructuredAiRequest request,
    ValidationOutcome<T> Function(Object?) validate) async =>
      (await _client()).readCached(request, validate);

  void clearMemoryCache() => _owned?.clearMemoryCache();

  /// 注入客户端的资源由本实例持有；运行时客户端由配置 provider 销毁。
  void dispose() => _owned?.dispose();
}

/// 生产入口只走供应商，未配置时不触碰数据库或网络。
final sentenceAiApiClientProvider = Provider<SentenceAiApiClient>((ref) {
  final client = SentenceAiApiClient.provider(structuredClient: () async =>
    (await ref.read(providerConfigurationProvider.future))?.structured);
  ref.onDispose(client.dispose);
  return client;
});
