/// 聊天客户端按调用时的供应商配置解析；配置 provider 持有连接生命周期。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/provider_configuration_provider.dart';
import '../models/chat_message.dart';
import '../services/chat_api_client.dart';
import '../services/ndjson_text_stream.dart';
import '../services/provider_chat_api_client.dart';

class _ConfiguredChatApi implements ChatApi {
  const _ConfiguredChatApi(this._runtime);
  final Future<ProviderRuntime?> Function() _runtime;
  @override
  Stream<ChatTextFrame> streamChat({required String endpoint,
    required List<ChatMessage> history, required Map<String, Object?> context,
    required String followUpInstruction, String? targetLanguage,
    required String accessToken, CancelToken? cancelToken}) async* {
    final runtime = await _runtime();
    if (runtime == null) throw const ProviderNotConfiguredException();
    yield* ProviderChatApiClient(config: runtime.config, http: runtime.http)
      .streamChat(endpoint: endpoint, history: history, context: context,
        followUpInstruction: followUpInstruction, targetLanguage: targetLanguage,
        accessToken: '', cancelToken: cancelToken);
  }
  @override
  void dispose() {}
}

final chatApiClientProvider = Provider<ChatApi>((ref) => _ConfiguredChatApi(
  () => ref.read(providerConfigurationProvider.future)));
