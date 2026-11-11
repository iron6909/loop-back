/// 供应商测试共用传输边界：真实 Dio、内存偏好与安全存储替身，全程不触网。
library;
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:loop_back/database/daos/sentence_ai_cache_dao.dart';
import 'package:loop_back/database/providers.dart';
import 'package:loop_back/providers/provider_configuration_provider.dart';
import 'package:loop_back/services/provider/provider_config.dart';
import 'package:loop_back/services/provider/provider_config_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FixtureAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final replies = <FutureOr<ResponseBody> Function(RequestOptions)>[];
  final arrived = StreamController<RequestOptions>.broadcast(sync: true);
  void json(Object body, {int status = 200}) => replies.add((_) => ResponseBody.fromString(
    jsonEncode(body), status, headers: {Headers.contentTypeHeader: [Headers.jsonContentType]}));
  void completion(Object value, {String finish = 'stop'}) => json({
    'choices': [{'finish_reason': finish, 'message': {'content': jsonEncode(value)}}],
  });
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
    Future<void>? cancelled) async {
    requests.add(options); arrived.add(options);
    if (replies.isEmpty) throw StateError('未提供测试响应');
    return replies.removeAt(0)(options);
  }
  @override
  void close({bool force = false}) {}
}
class _Secure extends Mock implements FlutterSecureStorage {}
class FixtureCache extends Mock implements SentenceAiCacheDao {}

const fixtureConfig = ProviderConfig(kind: ProviderKind.custom,
  baseUrl: 'https://provider.example/v1', model: 'fixture-model');

class ProviderFixture {
  ProviderFixture() {
    SharedPreferences.setMockInitialValues({});
    final secure = _Secure();
    String? key;
    when(() => secure.read(key: any(named: 'key'))).thenAnswer((_) async => key);
    when(() => secure.write(key: any(named: 'key'), value: any(named: 'value')))
      .thenAnswer((call) async { final value = call.namedArguments[#value]; key = value is String ? value : null; });
    when(() => secure.delete(key: any(named: 'key'))).thenAnswer((_) async { key = null; });
    when(() => cache.getByHash(any(), any())).thenAnswer((call) async =>
      stored['${call.positionalArguments[1]}:${call.positionalArguments[0]}']);
    when(() => cache.upsert(any(), any(), any())).thenAnswer((call) async {
      final args = call.positionalArguments;
      stored['${args[1]}:${args[0]}'] = '${args[2]}';
    });
    container = ProviderContainer(overrides: [
      providerConfigStoreProvider.overrideWithValue(ProviderConfigStore(secureStorage: secure)),
      providerDioFactoryProvider.overrideWithValue(() => Dio()..httpClientAdapter = adapter),
      sentenceAiCacheDaoProvider.overrideWithValue(cache),
    ]);
  }
  final adapter = FixtureAdapter();
  final cache = FixtureCache();
  final stored = <String, String>{};
  late final ProviderContainer container;
  Future<void> configure({ProviderConfig config = fixtureConfig, String key = 'synthetic-test-key'}) async {
    await container.read(providerConfigurationProvider.future);
    await container.read(providerConfigurationProvider.notifier).save(config, apiKey: key);
  }
  void dispose() { container.dispose(); unawaited(adapter.arrived.close()); }
}
