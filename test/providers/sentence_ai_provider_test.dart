/// 真实供应商入口：无登录、单次缓存、并发合并、取消及配置隔离。
library;
import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:echo_loop/providers/sentence_ai_provider.dart';
import 'package:echo_loop/services/provider/provider_config.dart';
import 'package:echo_loop/services/provider/structured_ai_client.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/provider_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderFixture fixture;
  setUp(() => fixture = ProviderFixture());
  tearDown(() => fixture.dispose());
  SentenceAiNotifier ai() => fixture.container.read(sentenceAiNotifierProvider);

  test('无配置不发请求，预加载不会触网', () async {
    expect(await ai().preloadTranslationFromDb('Hello', targetLanguage: 'zh-CN'), false);
    await expectLater(ai().getTranslationStream('Hello', targetLanguage: 'zh-CN').toList(),
      throwsA(isA<ProviderNotConfiguredException>()));
    expect(fixture.adapter.requests, isEmpty);
  });
  test('未登录可翻译，使用保存地址模型与 Key，缓存仅写一次', () async {
    await fixture.configure();
    fixture.adapter.completion({'translation': '你好'});
    final first = await ai().getTranslationStream('Hello', targetLanguage: 'zh-CN').toList();
    final second = await ai().getTranslationStream('Hello', targetLanguage: 'zh-CN').toList();
    expect(first.single.translation, '你好'); expect(second.single.translation, '你好');
    final request = fixture.adapter.requests.single;
    expect(request.uri.toString(), 'https://provider.example/v1/chat/completions');
    expect(request.headers['Authorization'], 'Bearer synthetic-test-key');
    expect(request.data, isA<Map<String, Object?>>().having((v) => v['model'], 'model', 'fixture-model'));
    expect(fixture.stored.length, 1);
    expect(fixture.stored.keys.single, contains('translation_v2:zh-CN:'));
  });
  test('并发同句只请求一次，最后一个订阅离开才取消', () async {
    await fixture.configure();
    final gate = Completer<ResponseBody>();
    fixture.adapter.replies.add((_) => gate.future);
    final arrived = fixture.adapter.arrived.stream.first;
    final first = ai().getTranslationStream('Hello', targetLanguage: 'zh-CN').last;
    final second = ai().getTranslationStream('Hello', targetLanguage: 'zh-CN').last;
    await arrived;
    gate.complete(ResponseBody.fromString(jsonEncode({'choices': [{
      'finish_reason': 'stop', 'message': {'content': '{"translation":"你好"}'},
    }]}), 200, headers: {Headers.contentTypeHeader: [Headers.jsonContentType]}));
    expect((await Future.wait([first, second])).map((t) => t.translation), ['你好', '你好']);
    expect(fixture.adapter.requests, hasLength(1));
  });
  test('无效结果不自动重试，不写缓存', () async {
    await fixture.configure(); fixture.adapter.completion({'translation': ''});
    await expectLater(ai().getTranslationStream('Hello', targetLanguage: 'zh-CN').toList(),
      throwsA(isA<StructuredValidationException>()));
    expect(fixture.adapter.requests, hasLength(1)); expect(fixture.stored, isEmpty);
  });
  test('模型切换清除页面缓存与在途结果，新请求用新模型', () async {
    await fixture.configure();
    fixture.adapter.completion({'translation': '旧值'});
    await ai().getTranslationStream('Hello', targetLanguage: 'zh-CN').last;
    await fixture.configure(config: const ProviderConfig(kind: ProviderKind.custom,
      baseUrl: 'https://provider.example/v1', model: 'new-model'));
    expect(ai().getCachedTranslation('Hello'), isNull);
    fixture.adapter.completion({'translation': '新值'});
    expect((await ai().getTranslationStream('Hello', targetLanguage: 'zh-CN').last).translation, '新值');
    expect(fixture.adapter.requests.length, 2); expect(fixture.stored.length, 2);
  });
  test('意群不守恒时报错且不落缓存', () async {
    await fixture.configure(); fixture.adapter.completion({'medium':['hello'], 'fine':['hello']});
    await expectLater(ai().getSenseGroupsStream('Hello').toList(),
      throwsA(isA<StructuredValidationException>()));
    expect(fixture.stored, isEmpty);
  });
}
