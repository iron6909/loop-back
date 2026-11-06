/// 聊天流式 API 抽象。
///
/// 供应商直连实现见 `provider_chat_api_client.dart`；后端的 NDJSON 聊天客户端
/// 已随自有后端停用移除。
library;

import 'package:dio/dio.dart';

import '../models/chat_message.dart';
import 'ndjson_text_stream.dart';

/// 聊天流式帧抽象：逐帧 yield 累计全文。
abstract interface class ChatApi {
  /// 发起一轮聊天，逐帧 yield 累计全文。
  ///
  /// [followUpInstruction]：追问引用的显式指令（本地化文案，按界面语言传入），
  /// 用于把带引用的消息拼成 `指令 + <quote>…</quote> + 问题`。
  Stream<ChatTextFrame> streamChat({
    required String endpoint,
    required List<ChatMessage> history,
    required Map<String, Object?> context,
    required String followUpInstruction,
    String? targetLanguage,
    required String accessToken,
    CancelToken? cancelToken,
  });

  /// 释放资源。
  void dispose();
}
