/// AI 词典源：只负责路由（单词/词组）与逐帧转发；缓存与凭据由统一客户端处理。
library;
import 'package:dio/dio.dart';
import 'package:loop_back/models/dictionary/dictionary_entry.dart';
import 'package:loop_back/models/dictionary/dictionary_lookup_result.dart';
import 'package:loop_back/services/dictionary/ai_dictionary_source.dart';
import 'package:loop_back/services/dictionary/dictionary_source.dart';
import 'package:loop_back/services/sentence_ai_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockApiClient extends Mock implements SentenceAiApiClient {}

DictionaryEntry _entry(String headword) => DictionaryEntry(
  headword: headword,
  pronunciation: const Pronunciation(uk: 'rʌn', us: 'rʌn'),
  meanings: const [],
  commonExpressions: const [],
  wordFamily: const [],
  forms: const [],
  etymology: '',
  learnerTips: const [],
);

MultiWordDictionaryEntry _multiEntry(String expression) =>
    MultiWordDictionaryEntry(
      originalExpression: expression,
      naturalness: '',
      category: '术语',
      pronunciationTips: const [],
      keyPoints: const [],
      meanings: const [
        MultiWordMeaning(translation: ['机器学习'], examples: []),
      ],
      similarExpressions: const [],
      background: '',
    );

Stream<AiDictionaryStreamFrame> _frames(AiDictionaryEntry entry,
        {bool isFinal = true}) =>
    Stream.value(AiDictionaryStreamFrame(entry: entry, isFinal: isFinal));

void main() {
  late MockApiClient api;
  late AiDictionarySource source;

  setUp(() {
    api = MockApiClient();
    source = AiDictionarySource(apiClient: () => api);
  });

  DictionaryLookupRequest request(String word, {String? token}) =>
      DictionaryLookupRequest(
        word: word,
        accessToken: token,
        targetLanguage: 'zh-CN',
      );

  test('单词（无空格）路由到 lookupWordStreamFrames', () async {
    when(
      () => api.lookupWordStreamFrames(
        'run',
        targetLanguage: 'zh-CN',
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => _frames(_entry('run')));

    final result = await source.lookup(request('run'));

    expect(result, isA<AiDictResult>());
    verify(
      () => api.lookupWordStreamFrames(
        'run',
        targetLanguage: 'zh-CN',
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
    verifyNever(
      () => api.lookupPhraseStreamFrames(
        any(),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  test('词组（含空格）路由到 lookupPhraseStreamFrames', () async {
    when(
      () => api.lookupPhraseStreamFrames(
        'machine learning',
        targetLanguage: 'zh-CN',
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => _frames(_multiEntry('machine learning')));

    final result = await source.lookup(request('machine learning'));

    expect(result, isA<AiDictResult>());
    verify(
      () => api.lookupPhraseStreamFrames(
        'machine learning',
        targetLanguage: 'zh-CN',
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
  });

  test('不再要求登录：无 accessToken 也直接查', () async {
    when(
      () => api.lookupWordStreamFrames(
        'run',
        targetLanguage: 'zh-CN',
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => _frames(_entry('run')));

    final result = await source.lookup(request('run', token: null));

    expect(result, isA<AiDictResult>());
  });

  test('逐帧转发，不自行截断', () async {
    final partial = _entry('run');
    when(
      () => api.lookupWordStreamFrames(
        'run',
        targetLanguage: 'zh-CN',
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) => Stream.fromIterable([
        AiDictionaryStreamFrame(entry: partial, isFinal: false),
        AiDictionaryStreamFrame(entry: partial, isFinal: true),
      ]),
    );

    final frames = await source.lookupStream(request('run')).toList();

    expect(frames, hasLength(2));
  });

  test('流内错误向上传播，不被吞掉', () async {
    when(
      () => api.lookupWordStreamFrames(
        'run',
        targetLanguage: 'zh-CN',
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) => Stream<AiDictionaryStreamFrame>.error(
        const DictionaryStreamException(),
      ),
    );

    await expectLater(
      source.lookupStream(request('run')).toList(),
      throwsA(isA<DictionaryStreamException>()),
    );
  });

  test('取消后不再转发后续帧', () async {
    final token = CancelToken();
    when(
      () => api.lookupWordStreamFrames(
        'run',
        targetLanguage: 'zh-CN',
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async* {
        yield AiDictionaryStreamFrame(entry: _entry('run'), isFinal: false);
        token.cancel('closed');
        yield AiDictionaryStreamFrame(entry: _entry('run'), isFinal: true);
      },
    );

    final frames = await source
        .lookupStream(request('run'), cancelToken: token)
        .toList();

    expect(frames, hasLength(1));
  });

  test('lookup 返回最后一帧', () async {
    when(
      () => api.lookupWordStreamFrames(
        'run',
        targetLanguage: 'zh-CN',
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) => Stream.fromIterable([
        AiDictionaryStreamFrame(entry: _entry('partial'), isFinal: false),
        AiDictionaryStreamFrame(entry: _entry('final'), isFinal: true),
      ]),
    );

    final result = await source.lookup(request('run'));

    expect(result?.headword, 'final');
  });

  test('清缓存委托给统一客户端', () {
    source.clearMemoryCache();
    verify(() => api.clearMemoryCache()).called(1);
  });
}
