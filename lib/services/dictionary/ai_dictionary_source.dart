/// AI 词典源：由当前供应商完成请求、校验和缓存，不读取登录或会员状态。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../database/daos/sentence_ai_cache_dao.dart';
import '../../models/dictionary/dictionary_lookup_result.dart';
import '../../utils/text_normalize.dart';
import '../sentence_ai_api_client.dart';
import 'dictionary_source.dart';

class AiDictionarySource implements DictionarySource {
  AiDictionarySource({required ValueGetter<SentenceAiCacheDao> cacheDao,
    required ValueGetter<SentenceAiApiClient> apiClient}) : _api = apiClient;
  final ValueGetter<SentenceAiApiClient> _api;
  static const sourceId = 'ai';
  @override
  String get id => sourceId;
  @override
  IconData get icon => Icons.auto_awesome;
  @override
  bool get canBeDisabled => false;
  @override
  bool get requiresNetwork => true;
  void clearMemoryCache() => _api().clearMemoryCache();

  Stream<DictionaryLookupResult?> lookupStream(DictionaryLookupRequest request,
    {CancelToken? cancelToken}) async* {
    final client = _api();
    final stream = normalizeWord(request.word).contains(' ')
      ? client.lookupPhraseStreamFrames(request.word,
          targetLanguage: request.targetLanguage, cancelToken: cancelToken)
      : client.lookupWordStreamFrames(request.word,
          targetLanguage: request.targetLanguage, cancelToken: cancelToken);
    await for (final frame in stream) {
      if (cancelToken?.isCancelled ?? false) return;
      yield AiDictResult(frame.entry);
    }
  }

  @override
  Future<DictionaryLookupResult?> lookup(DictionaryLookupRequest request,
    {CancelToken? cancelToken}) async {
    DictionaryLookupResult? last;
    await for (final value in lookupStream(request, cancelToken: cancelToken)) {
      last = value;
    }
    return last;
  }
}
