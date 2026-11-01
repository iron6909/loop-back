/// 供应商客户端六项功能：请求契约、严格校验与缓存写入。
library;
import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:echo_loop/models/dictionary/dictionary_entry.dart';
import 'package:echo_loop/models/sense_group_result.dart';
import 'package:echo_loop/services/provider/provider_config.dart';
import 'package:echo_loop/services/provider/structured_ai_client.dart';
import 'package:echo_loop/services/sentence_ai_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/provider_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderFixture fixture;
  late SentenceAiApiClient client;
  setUp(() {
    fixture = ProviderFixture();
    client = SentenceAiApiClient.withDio(Dio()..httpClientAdapter = fixture.adapter,
      config: fixtureConfig, apiKey: 'synthetic-test-key');
  });
  tearDown(() => fixture.dispose());

  Map<String, Object?> body() => fixture.adapter.requests.single.data as Map<String, Object?>;

  test('翻译请求带模型、严格 Schema 与关闭思考', () async {
    fixture.adapter.completion({'translation': '你好'});
    await client.translateStream('Hello', previousText: 'A.', nextText: 'B.',
      targetLanguage: 'zh-CN').last;
    expect(fixture.adapter.requests.single.uri.path, '/v1/chat/completions');
    final data = body();
    expect(data['model'], 'fixture-model');
    expect((data['response_format'] as Map)['type'], 'json_schema');
    final user = (data['messages'] as List).last as Map;
    final payload = jsonDecode(user['content'] as String) as Map;
    expect(payload['text'], 'Hello'); expect(payload['previousText'], 'A.');
    expect(payload['nextText'], 'B.'); expect(payload['targetLanguage'], 'zh-CN');
  });

  test('六项功能各自产出一帧终帧', () async {
    fixture.adapter.completion({'translation': '译文'});
    expect((await client.translateStream('Hello').last).isFinal, isTrue);
    fixture.adapter.completion({'grammar': [{'point': 'g', 'note': 'n'}],
      'listening': [{'phrase': 'p', 'note': 'n'}], 'vocabulary': []});
    expect((await client.analyzeStream('Hello').last).isFinal, isTrue);
    fixture.adapter.completion({'headword': 'hello', 'meanings': [
      {'partOfSpeech': 'n', 'definition': 'greeting', 'translation': ['你好']}]});
    expect((await client.lookupWordStreamFrames('hello').last).entry, isA<AiDictionaryEntry>());
    fixture.adapter.completion({'originalExpression': 'hello there', 'category': 'greeting',
      'keyPoints': [{'point': 'p'}], 'meanings': [{'translation': ['你好']}]});
    expect((await client.lookupPhraseStreamFrames('hello there').last).isFinal, isTrue);
    fixture.adapter.completion({'medium': ['Hello'], 'fine': ['Hello']});
    expect((await client.senseGroupsStream('Hello').last).result, isA<SenseGroupResult>());
    fixture.adapter.completion({'rating': 'good', 'summary': '好', 'keyPoints': [
      {'keyPoint': 'k', 'status': 'covered'}], 'corrections': []});
    final retell = await client.evaluateTranscriptStream(transcript: 'I said',
      originalText: 'I said', targetLanguage: 'zh-CN').last;
    expect(retell.evaluation.transcript, 'I said');
  });

  test('finish_reason=length 判失败，不写缓存', () async {
    fixture.adapter.completion({'translation': '半截'}, finish: 'length');
    await expectLater(client.translateStream('Hello').toList(),
      throwsA(isA<StructuredValidationException>()));
    expect(fixture.stored, isEmpty);
  });

  test('非 JSON 与字段类型错误均判失败', () async {
    fixture.adapter.json({'choices': [{'finish_reason': 'stop',
      'message': {'content': 'not json'}}]});
    await expectLater(client.translateStream('Hello').toList(),
      throwsA(isA<StructuredValidationException>()));
    fixture.adapter.completion({'translation': 42});
    await expectLater(client.translateStream('Hello').toList(),
      throwsA(isA<StructuredValidationException>()));
    expect(fixture.stored, isEmpty);
  });

  test('未配置时抛出明确错误且不发请求', () async {
    final unconfigured = SentenceAiApiClient.provider(structuredClient: () async => null);
    await expectLater(unconfigured.translateStream('Hello').toList(),
      throwsA(isA<ProviderNotConfiguredException>()));
    expect(fixture.adapter.requests, isEmpty);
  });

  test('取消后不产出终帧也不写缓存', () async {
    final gate = Completer<void>();
    fixture.adapter.replies.add((_) async {
      await gate.future;
      return ResponseBody.fromString(jsonEncode({'choices': [{
        'finish_reason': 'stop', 'message': {'content': '{"translation":"你好"}'},
      }]}), 200, headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
    });
    final token = CancelToken();
    final frames = <bool>[];
    final arrived = fixture.adapter.arrived.stream.first;
    final consuming = () async {
      await for (final frame in client.translateStream('Hello', cancelToken: token)) {
        frames.add(frame.isFinal);
      }
    }();
    await arrived;
    token.cancel('user stopped');
    gate.complete();
    await consuming;
    expect(frames, isEmpty);
  });
}
