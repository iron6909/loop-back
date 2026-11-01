/// 句子 AI 的页面接口：共享请求，保留同步展示缓存；持久缓存由结构化客户端负责。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/sentence_ai_cache_dao.dart';
import '../database/providers.dart';
import '../models/sense_group_result.dart';
import '../models/sentence_ai_result.dart';
import '../services/provider/structured_ai_client.dart';
import '../services/provider/structured_prompts.dart';
import '../services/provider/structured_result_validator.dart';
import '../services/sentence_ai_api_client.dart';
import '../utils/text_normalize.dart';
import 'provider_configuration_provider.dart';

/// 同一次页面查询的消费者共享底层请求，最后一位离开时取消网络。
class _SharedRequest<T> {
  _SharedRequest(Stream<T> Function(CancelToken) load) {
    stream = Stream<T>.multi((subscriber) {
      _listeners++;
      final subscription = _events.stream.listen(subscriber.add,
        onError: subscriber.addError, onDone: subscriber.close);
      if (_latest case final value?) subscriber.add(value);
      subscriber.onCancel = () async {
        await subscription.cancel();
        if (--_listeners == 0 && !_finished) token.cancel('no listeners');
      };
      if (!_started) {
        _started = true;
        unawaited(_run(load));
      }
    }, isBroadcast: true);
  }
  final token = CancelToken();
  final _events = StreamController<T>.broadcast(sync: true);
  late final Stream<T> stream;
  T? _latest;
  var _listeners = 0;
  var _started = false;
  var _finished = false;

  Future<void> _run(Stream<T> Function(CancelToken) load) async {
    try {
      await for (final value in load(token)) {
        if (token.isCancelled) break;
        _latest = value;
        _events.add(value);
      }
    } catch (error, stack) {
      if (!token.isCancelled) _events.addError(error, stack);
    } finally {
      _finished = true;
      await _events.close();
    }
  }
}

class SentenceAiNotifier {
  SentenceAiNotifier({required SentenceAiApiClient apiClient,
    required SentenceAiCacheDao cacheDao}) : _api = apiClient;

  final SentenceAiApiClient _api;
  final _translations = <String, SentenceTranslation>{};
  final _analyses = <String, SentenceAnalysis>{};
  final _groups = <String, SenseGroupResult>{};
  final _pendingTranslations = <String, _SharedRequest<SentenceTranslation>>{};
  final _pendingAnalyses = <String, _SharedRequest<SentenceAnalysis>>{};
  final _pendingGroups = <String, _SharedRequest<SenseGroupResult>>{};
  var _generation = 0;

  /// accessToken 和 respectLocalQuotaReset 为旧页面签名保留，不再参与门控。
  Stream<SentenceTranslation> getTranslationStream(String text, {
    required String targetLanguage, String? previous, String? next,
    String? accessToken, CancelToken? cancelToken,
    bool respectLocalQuotaReset = false,
  }) => _share(
    '${translationContextHash(text, previous: previous, next: next)}:$targetLanguage',
    _translations, _pendingTranslations,
    (token) => _api.translateStream(text, previousText: previous, nextText: next,
      targetLanguage: targetLanguage, cancelToken: token)
      .where((f) => f.isFinal).map((f) => f.translation), cancelToken,
  );

  Stream<SentenceAnalysis> getAnalysisStream(String text, {
    required String targetLanguage, String? accessToken, CancelToken? cancelToken,
    bool respectLocalQuotaReset = false,
  }) => _share('${hashText(text)}:$targetLanguage', _analyses, _pendingAnalyses,
    (token) => _api.analyzeStream(text, targetLanguage: targetLanguage,
      cancelToken: token).where((f) => f.isFinal).map((f) => f.analysis), cancelToken);

  Stream<SenseGroupResult> getSenseGroupsStream(String text, {
    String? accessToken, CancelToken? cancelToken,
    bool respectLocalQuotaReset = false,
  }) => _share(hashText(text), _groups, _pendingGroups,
    (token) => _api.senseGroupsStream(text, cancelToken: token)
      .where((f) => f.isFinal).map((f) => f.result), cancelToken);

  /// 每位订阅者可独立取消；配置切换使整组请求与展示缓存同时失效。
  Stream<T> _share<T>(String key, Map<String, T> memory,
    Map<String, _SharedRequest<T>> pending,
    Stream<T> Function(CancelToken) load, CancelToken? callerToken) async* {
    if (callerToken?.isCancelled ?? false) return;
    if (memory[key] case final value?) { yield value; return; }
    final generation = _generation;
    final request = pending.putIfAbsent(key, () => _SharedRequest<T>((token) async* {
      try {
        await for (final value in load(token)) {
          if (generation != _generation || token.isCancelled) return;
          memory[key] = value;
          yield value;
        }
      } finally {
        pending.remove(key);
      }
    }));
    final stream = request.stream;
    if (callerToken == null) {
      yield* stream;
    } else {
      // takeUntil 用真实取消信号，避免等到下一帧才响应关闭。
      final controller = StreamController<T>();
      final subscription = stream.listen(controller.add,
        onError: controller.addError, onDone: controller.close);
      unawaited(callerToken.whenCancel.then((_) async {
        await subscription.cancel();
        if (!controller.isClosed) await controller.close();
      }));
      try { yield* controller.stream; }
      finally { await subscription.cancel(); }
    }
  }

  SentenceTranslation? getCachedTranslation(String text, {
    String? previous, String? next, String? targetLanguage,
  }) => _cached(_translations,
    translationContextHash(text, previous: previous, next: next), targetLanguage);

  SentenceAnalysis? getCachedAnalysis(String text, {String? targetLanguage}) =>
    _cached(_analyses, hashText(text), targetLanguage);

  T? _cached<T>(Map<String, T> memory, String hash, String? language) {
    if (language != null) return memory['$hash:$language'];
    return memory.entries.where((e) => e.key.startsWith('$hash:')).firstOrNull?.value;
  }

  SenseGroupResult? getCachedSenseGroups(String text) => _groups[hashText(text)];

  Future<bool> preloadTranslationFromDb(String text, {
    required String targetLanguage, String? previous, String? next,
  }) => _preload(StructuredAiRequest(feature: StructuredFeature.translation,
    text: text, targetLanguage: targetLanguage, previousText: previous, nextText: next),
    validateTranslation, _translations,
    '${translationContextHash(text, previous: previous, next: next)}:$targetLanguage');

  Future<bool> preloadAnalysisFromDb(String text, {required String targetLanguage}) =>
    _preload(StructuredAiRequest(feature: StructuredFeature.analysis,
      text: text, targetLanguage: targetLanguage), validateAnalysis,
      _analyses, '${hashText(text)}:$targetLanguage');

  Future<bool> preloadSenseGroupsFromDb(String text) => _preload(
    StructuredAiRequest(feature: StructuredFeature.senseGroups, text: text),
    (value) => validateSenseGroups(value, original: text), _groups, hashText(text));

  Future<bool> _preload<T>(StructuredAiRequest request,
    ValidationOutcome<T> Function(Object?) validate, Map<String, T> memory,
    String key) async {
    final generation = _generation;
    try {
      final value = await _api.readCached(request, validate);
      if (value == null || generation != _generation) return false;
      memory[key] = value;
      return true;
    } on ProviderNotConfiguredException {
      return false;
    }
  }

  /// 配置切换、数据库切换及清缓存时作废回调，历史数据库行不删除。
  void clearMemoryCache() {
    _generation++;
    for (final p in _pendingTranslations.values) { p.token.cancel('invalidated'); }
    for (final p in _pendingAnalyses.values) { p.token.cancel('invalidated'); }
    for (final p in _pendingGroups.values) { p.token.cancel('invalidated'); }
    _pendingTranslations.clear(); _pendingAnalyses.clear(); _pendingGroups.clear();
    _translations.clear(); _analyses.clear(); _groups.clear();
    _api.clearMemoryCache();
  }
}

/// 不读取认证与订阅状态，保存供应商配置时立即清除旧页面数据。
final sentenceAiNotifierProvider = Provider<SentenceAiNotifier>((ref) {
  final notifier = SentenceAiNotifier(apiClient: ref.watch(sentenceAiApiClientProvider),
    cacheDao: ref.watch(sentenceAiCacheDaoProvider));
  ref.listen(providerConfigurationProvider, (previous, _) {
    if (previous != null && !previous.isLoading) notifier.clearMemoryCache();
  });
  ref.onDispose(notifier.clearMemoryCache);
  return notifier;
});
