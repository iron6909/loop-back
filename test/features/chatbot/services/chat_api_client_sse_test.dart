/// 供应商聊天 SSE 回归：完整结束、断流、UTF-8 分片及取消。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/features/chatbot/models/chat_message.dart';
import 'package:echo_loop/features/chatbot/services/provider_chat_api_client.dart';
import 'package:echo_loop/features/chatbot/services/ndjson_text_stream.dart';
import 'package:echo_loop/services/provider/provider_config.dart';
import 'package:echo_loop/services/provider/provider_http_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  Stream<Uint8List> bytes = const Stream.empty();
  RequestOptions? request;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody(bytes, 200);
  }

  @override
  void close({bool force = false}) {}
}

String event({String? content, String? finish}) =>
    'data: ${jsonEncode({
      'choices': [
        {
          'index': 0,
          'delta': {'content': content},
          'finish_reason': finish,
        },
      ],
    })}\n\n';

void main() {
  late _Adapter adapter;
  late ProviderChatApiClient client;
  setUp(() {
    adapter = _Adapter();
    const config = ProviderConfig(
      kind: ProviderKind.custom,
      baseUrl: 'https://example.com/api/v1',
      model: 'chosen-model',
    );
    client = ProviderChatApiClient(
      config: config,
      http: ProviderHttpClient(
        config: config,
        apiKey: 'fixture-key',
        dio: Dio()..httpClientAdapter = adapter,
      ),
    );
  });
  tearDown(() => client.dispose());

  Stream<ChatTextFrame> request({CancelToken? cancel}) => client.streamChat(
    endpoint: '/ignored-backend-route',
    history: [
      ChatMessage.user(
        id: 'u',
        content: 'Explain this.',
        createdAt: DateTime.utc(2026),
      ),
    ],
    context: const {'sentence': 'Hello world.'},
    followUpInstruction: 'Explain the quote.',
    targetLanguage: 'zh-CN',
    accessToken: 'ignored-supabase-token',
    cancelToken: cancel,
  );

  void respond(String text, {bool splitBytes = false}) {
    final bytes = utf8.encode(text);
    adapter.bytes = Stream.fromIterable(
      splitBytes
          ? bytes.map((b) => Uint8List.fromList([b]))
          : [Uint8List.fromList(bytes)],
    );
  }

  test('正文累计，空 finish 帧不增加正文，stop 与 DONE 都有才完成', () async {
    respond(
      '${event(content: '你')}${event(content: '好')}'
      '${event(finish: 'stop')}data: [DONE]\n\n',
    );
    final frames = await request().toList();
    expect(frames.map((f) => f.text), ['你', '你好', '你好']);
    expect(frames.map((f) => f.isFinal), [false, false, true]);
    expect(
      adapter.request?.uri.toString(),
      'https://example.com/api/v1/chat/completions',
    );
    expect(adapter.request?.headers['Authorization'], 'Bearer fixture-key');
    final body = adapter.request?.data;
    expect(
      body,
      isA<Map<String, Object?>>().having(
        (b) => b['model'],
        'model',
        'chosen-model',
      ),
    );
  });

  test('UTF-8 每字节跨分片且 CRLF 仍可正确解码', () async {
    respond(
      '${event(content: '你好🌍')}${event(finish: 'stop')}'
              'data: [DONE]\n\n'
          .replaceAll('\n', '\r\n'),
      splitBytes: true,
    );
    expect((await request().toList()).last.text, '你好🌍');
  });

  for (final tail in [
    event(finish: 'stop'),
    'data: [DONE]\n\n',
    '${event(finish: 'length')}data: [DONE]\n\n',
  ]) {
    test('缺 stop 或 DONE 或 length 均不能完成：$tail', () async {
      respond('${event(content: 'partial')}$tail');
      final frames = <ChatTextFrame>[];
      await expectLater(
        request().map((f) {
          frames.add(f);
          return f;
        }).toList(),
        throwsA(isA<ChatStreamException>()),
      );
      expect(frames.every((f) => !f.isFinal), isTrue);
      expect(frames.first.text, 'partial');
    });
  }

  test('多行 data 与注释、usage 空 choices 帧被正确处理', () async {
    respond(
      ': heartbeat\n\ndata: {"choices":\n'
      'data: [{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n'
      'data: {"choices":[],"usage":{"total_tokens":4}}\n\n'
      'data: [DONE]\n\n',
    );
    expect((await request().toList()).last.text, 'ok');
  });

  test('用户停止保留已有文本且无终帧', () async {
    final token = CancelToken();
    respond(
      '${event(content: 'partial')}${event(content: 'discard')}'
      '${event(finish: 'stop')}data: [DONE]\n\n',
    );
    final frames = <ChatTextFrame>[];
    await request(cancel: token).forEach((f) {
      frames.add(f);
      token.cancel('user stopped');
    });
    expect(frames.map((f) => f.text), ['partial']);
    expect(frames.single.isFinal, isFalse);
  });
}
