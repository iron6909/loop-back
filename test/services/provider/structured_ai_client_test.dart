/// 结构化 AI 客户端测试
///
/// 覆盖六功能共用流水线：输出模式选择、严格校验、缓存写入时机、generation 作废。
/// 全程用假 adapter，不触网、不调真实供应商。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/models/sentence_ai_result.dart';
import 'package:echo_loop/services/provider/provider_config.dart';
import 'package:echo_loop/services/provider/provider_http_client.dart';
import 'package:echo_loop/services/provider/structured_ai_client.dart';
import 'package:echo_loop/services/provider/structured_prompts.dart';
import 'package:echo_loop/services/provider/structured_result_validator.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录请求、按队列回放响应，并支持挂起以模拟在途请求。
class _FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<ResponseBody> _responses = [];
  Completer<void>? gate;
  final started = Completer<void>();

  void enqueueChat(Object content, {String finishReason = 'stop'}) {
    enqueuePayload({
      'choices': [
        {
          'finish_reason': finishReason,
          'message': {
            'content': content is String ? content : jsonEncode(content),
          },
        },
      ],
    });
  }

  void enqueuePayload(Object payload, {int status = 200}) {
    _responses.add(
      ResponseBody.fromString(
        jsonEncode(payload),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (!started.isCompleted) started.complete();
    final waiting = gate;
    if (waiting != null) await waiting.future;
    if (_responses.isEmpty) throw StateError('没有预设响应');
    return _responses.removeAt(0);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _FakeAdapter adapter;
  late Dio dio;
  late List<Map<String, String>> cacheWrites;

  setUp(() {
    adapter = _FakeAdapter();
    dio = Dio()..httpClientAdapter = adapter;
    cacheWrites = [];
  });

  StructuredAiClient buildClient({
    ProviderKind kind = ProviderKind.deepseek,
    String baseUrl = 'https://api.deepseek.com',
  }) => StructuredAiClient(
    http: ProviderHttpClient(
      config: ProviderConfig(kind: kind, baseUrl: baseUrl, model: 'm'),
      apiKey: 'sk-test',
      dio: dio,
    ),
    config: ProviderConfig(kind: kind, baseUrl: baseUrl, model: 'm'),
    writeCache: ({required type, required textHash, required payload}) async {
      cacheWrites.add({'type': type, 'hash': textHash, 'payload': payload});
    },
  );

  StructuredAiRequest translationRequest() => const StructuredAiRequest(
    feature: StructuredFeature.translation,
    text: 'This is a test.',
    targetLanguage: 'zh-CN',
  );

  group('成功路径', () {
    test('产出一帧终帧并写一次缓存', () async {
      adapter.enqueueChat({'translation': '这是一个测试。'});
      final client = buildClient();

      final frames = await client
          .stream<SentenceTranslation>(
            request: translationRequest(),
            validate: validateTranslation,
          )
          .toList();

      expect(frames.length, 1);
      expect(frames.single.isFinal, isTrue);
      expect(frames.single.value.translation, '这是一个测试。');
      expect(cacheWrites.length, 1);
      expect(cacheWrites.single['payload'], contains('这是一个测试。'));
    });

    test('缓存类型含配置指纹与语言，旧配置不会命中', () async {
      adapter.enqueueChat({'translation': 'a'});
      adapter.enqueueChat({'translation': 'b'});

      await buildClient()
          .stream<SentenceTranslation>(
            request: translationRequest(),
            validate: validateTranslation,
          )
          .toList();
      await buildClient(kind: ProviderKind.custom, baseUrl: 'https://x.test')
          .stream<SentenceTranslation>(
            request: translationRequest(),
            validate: validateTranslation,
          )
          .toList();

      expect(cacheWrites.first['type'], startsWith('translation_v2:zh-CN:'));
      expect(cacheWrites.first['type'], isNot(cacheWrites.last['type']));
    });

    test('DeepSeek 使用受支持的 JSON 输出且关闭思考', () async {
      adapter.enqueueChat({'translation': 'a'});
      await buildClient()
          .stream<SentenceTranslation>(
            request: translationRequest(),
            validate: validateTranslation,
          )
          .toList();

      final body = adapter.requests.single.data as Map<String, Object?>;
      expect(body['thinking'], {'type': 'disabled'});
      final format = body['response_format'] as Map<String, Object?>;
      expect(format, {'type': 'json_object'});
      expect(body['messages'], isA<List<Object?>>());
      final messages = body['messages'];
      if (messages case [
        {'role': 'system', 'content': final String system},
        ...,
      ]) {
        expect(system, contains('"translation"'));
        expect(system, contains('"required"'));
      } else {
        fail('缺少系统消息中的结构定义');
      }
    });

    test('DeepSeek 解析明确区分词汇 term 与听力 phrase', () async {
      adapter.enqueueChat({
        'grammar': [
          {'point': '现在时', 'note': '描述事实'},
        ],
        'vocabulary': [
          {'term': 'test', 'note': '测试'},
        ],
        'listening': [
          {'phrase': 'This is', 'note': '连读'},
        ],
      });
      await buildClient()
          .stream(
            request: const StructuredAiRequest(
              feature: StructuredFeature.analysis,
              text: 'This is a test.',
            ),
            validate: validateAnalysis,
          )
          .toList();
      if (adapter.requests.single.data case {
        'messages': [{'role': 'system', 'content': final String system}, ...],
      }) {
        expect(system, contains('"vocabulary":[{"term":'));
        expect(system, contains('"listening":[{"phrase":'));
      } else {
        fail('解析请求缺少完整输出示例');
      }
    });

    test('OpenRouter 请求要求模型真正支持参数', () async {
      adapter.enqueueChat({'translation': 'a'});
      await buildClient(
            kind: ProviderKind.openrouter,
            baseUrl: 'https://openrouter.ai/api/v1',
          )
          .stream<SentenceTranslation>(
            request: translationRequest(),
            validate: validateTranslation,
          )
          .toList();

      final body = adapter.requests.single.data as Map<String, Object?>;
      expect(body['provider'], {'require_parameters': true});
      expect(body['response_format'], {
        'type': 'json_schema',
        'json_schema': {
          'name': 'sentence_translation',
          'strict': true,
          'schema': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['translation'],
            'properties': {
              'translation': {'type': 'string', 'description': '目标语言译文，单句'},
            },
          },
        },
      });
      expect(body.containsKey('thinking'), isFalse);
    });
  });

  group('失败不写缓存', () {
    test('听力项返回 term 而非 phrase 时拒绝且不缓存', () async {
      adapter.enqueueChat({
        'grammar': [
          {'point': '现在时', 'note': '描述事实'},
        ],
        'vocabulary': <Object?>[],
        'listening': [
          {'term': 'This is', 'note': '连读'},
        ],
      });
      await expectLater(
        buildClient()
            .stream(
              request: const StructuredAiRequest(
                feature: StructuredFeature.analysis,
                text: 'This is a test.',
              ),
              validate: validateAnalysis,
            )
            .toList(),
        throwsA(
          isA<StructuredValidationException>().having(
            (error) => error.reason,
            'reason',
            ValidationFailureReason.missingField,
          ),
        ),
      );
      expect(adapter.requests, hasLength(1));
      expect(cacheWrites, isEmpty);
    });

    Future<ValidationFailureReason> reasonFor(
      Object content, {
      StructuredAiRequest? request,
      String finishReason = 'stop',
    }) async {
      adapter.enqueueChat(content, finishReason: finishReason);
      try {
        await buildClient()
            .stream<SentenceTranslation>(
              request: request ?? translationRequest(),
              validate: validateTranslation,
            )
            .toList();
      } on StructuredValidationException catch (error) {
        return error.reason;
      }
      fail('应当抛出 StructuredValidationException');
    }

    test('字段为空判失败且不写缓存', () async {
      expect(
        await reasonFor({'translation': '  '}),
        ValidationFailureReason.missingField,
      );
      expect(cacheWrites, isEmpty);
    });

    test('finish_reason=length 判截断', () async {
      expect(
        await reasonFor({'translation': 'a'}, finishReason: 'length'),
        ValidationFailureReason.truncated,
      );
      expect(cacheWrites, isEmpty);
    });

    test('空正文判空', () async {
      expect(await reasonFor(''), ValidationFailureReason.emptyBody);
      expect(cacheWrites, isEmpty);
    });

    test('正文非 JSON 判非对象', () async {
      expect(
        await reasonFor('not json at all'),
        ValidationFailureReason.notJsonObject,
      );
      expect(cacheWrites, isEmpty);
    });
  });

  group('输出模式回落', () {
    test('明确不支持严格 Schema 时回落一次并成功', () async {
      adapter.enqueuePayload({
        'error': {'message': 'response_format is not supported'},
      }, status: 400);
      adapter.enqueueChat({'translation': 'ok'});

      final frames = await buildClient(kind: ProviderKind.custom)
          .stream<SentenceTranslation>(
            request: translationRequest(),
            validate: validateTranslation,
          )
          .toList();

      expect(adapter.requests.length, 2);
      final fallback = adapter.requests.last.data as Map<String, Object?>;
      expect(fallback['response_format'], {'type': 'json_object'});
      if (fallback['messages'] case [
        {'role': 'system', 'content': final String system},
        ...,
      ]) {
        expect(system, contains('"translation"'));
      } else {
        fail('兼容模式缺少输出字段定义');
      }
      expect(frames.single.value.translation, 'ok');
    });

    test('回落只发生一次，二次失败即报错', () async {
      adapter.enqueuePayload({
        'error': {'message': 'response_format is not supported'},
      }, status: 400);
      adapter.enqueuePayload({
        'error': {'message': 'json_schema is not supported'},
      }, status: 400);

      await expectLater(
        buildClient(kind: ProviderKind.custom)
            .stream<SentenceTranslation>(
              request: translationRequest(),
              validate: validateTranslation,
            )
            .toList(),
        throwsA(isA<ProviderHttpException>()),
      );
      expect(adapter.requests.length, 2);
    });

    test('校验失败不触发回落', () async {
      adapter.enqueueChat({'translation': ''});

      await expectLater(
        buildClient()
            .stream<SentenceTranslation>(
              request: translationRequest(),
              validate: validateTranslation,
            )
            .toList(),
        throwsA(isA<StructuredValidationException>()),
      );
      expect(adapter.requests.length, 1);
    });
  });

  final fixtures = <StructuredFeature, Map<String, Object?>>{
    StructuredFeature.translation: {'translation': '译文'},
    StructuredFeature.analysis: {
      'grammar': [
        {'point': '时态', 'note': '现在时'},
      ],
      'vocabulary': <Object?>[],
      'listening': [
        {'phrase': 'This is', 'note': '连读'},
      ],
    },
    StructuredFeature.word: {
      'headword': 'test',
      'meanings': [
        {
          'partOfSpeech': 'n.',
          'definition': 'an examination',
          'translation': ['测试'],
        },
      ],
    },
    StructuredFeature.phrase: {
      'originalExpression': 'give up',
      'category': '短语动词',
      'keyPoints': [
        {'point': '放弃'},
      ],
      'meanings': [
        {
          'translation': ['放弃'],
        },
      ],
    },
    StructuredFeature.senseGroups: {
      'medium': ['This is', ' a test.'],
      'fine': ['This', ' is', ' a', ' test.'],
    },
    StructuredFeature.retell: {
      'rating': 'good',
      'summary': '准确',
      'keyPoints': [
        {'keyPoint': '测试', 'status': 'covered'},
      ],
      'corrections': <Object?>[],
    },
  };
  ValidationOutcome<Object> check(StructuredFeature feature, Object? value) =>
      switch (feature) {
        StructuredFeature.translation => validateTranslation(value),
        StructuredFeature.analysis => validateAnalysis(value),
        StructuredFeature.word => validateWordEntry(value),
        StructuredFeature.phrase => validatePhraseEntry(value),
        StructuredFeature.senseGroups => validateSenseGroups(
          value,
          original: 'This is a test.',
        ),
        StructuredFeature.retell => validateRetell(value),
      };
  for (final entry in fixtures.entries) {
    test('${entry.key.name} 成功仅发终帧，第二次读缓存不发请求', () async {
      adapter.enqueueChat(entry.value);
      final client = buildClient();
      final request = StructuredAiRequest(
        feature: entry.key,
        text: 'This is a test.',
        targetLanguage: 'zh-CN',
      );
      final first = await client
          .stream<Object>(
            request: request,
            validate: (value) => check(entry.key, value),
          )
          .toList();
      final second = await client
          .stream<Object>(
            request: request,
            validate: (value) => check(entry.key, value),
          )
          .toList();
      expect(first.single.isFinal, isTrue);
      expect(second.single.isFinal, isTrue);
      expect(adapter.requests, hasLength(1));
      expect(cacheWrites, hasLength(1));
    });
    test('${entry.key.name} 无效结果不缓存也不回落', () async {
      adapter.enqueueChat(<String, Object?>{});
      final request = StructuredAiRequest(
        feature: entry.key,
        text: 'This is a test.',
      );
      await expectLater(
        buildClient()
            .stream<Object>(
              request: request,
              validate: (value) => check(entry.key, value),
            )
            .toList(),
        throwsA(isA<StructuredValidationException>()),
      );
      expect(cacheWrites, isEmpty);
      expect(adapter.requests, hasLength(1));
    });
  }

  test('取消后不写缓存、不产出终帧', () async {
    final gate = Completer<void>();
    adapter.gate = gate;
    adapter.enqueueChat({'translation': 'late'});
    final token = CancelToken();
    final pending = buildClient()
        .stream(
          request: translationRequest(),
          validate: validateTranslation,
          cancelToken: token,
        )
        .toList();
    await adapter.started.future;
    token.cancel();
    gate.complete();
    expect(await pending, isEmpty);
    expect(cacheWrites, isEmpty);
  });

  group('generation 作废', () {
    test('配置切换后在途结果不产出也不写缓存', () async {
      final gate = Completer<void>();
      adapter.gate = gate;
      adapter.enqueueChat({'translation': 'late'});
      final client = buildClient();

      final pending = client
          .stream<SentenceTranslation>(
            request: translationRequest(),
            validate: validateTranslation,
          )
          .toList();
      await adapter.started.future;
      client.invalidate();
      gate.complete();

      expect(await pending, isEmpty);
      expect(cacheWrites, isEmpty);
    });
  });
}
