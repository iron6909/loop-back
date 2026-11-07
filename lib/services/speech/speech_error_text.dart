/// 在线语音失败的用户文案；只显示分类，不展示响应原文或凭据。
///
/// 与文字 AI 共享同一套既有分类文案（鉴权、余额、地址/模型、限流、超时、服务、
/// 网络），只额外补充语音特有的分类，避免两套说法不一致。
library;

import 'package:flutter/widgets.dart';

import '../provider/provider_error_text.dart';
import 'speech_transcription_client.dart';

String speechErrorText(BuildContext context, Object error) {
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  if (error is! SpeechTranscriptionException) {
    return providerErrorCodeText('invalidResponse', zh);
  }
  return switch (error.kind) {
    SpeechTranscriptionErrorKind.unsupportedCapability =>
      zh
          ? '该服务不支持所需的输出格式或时间戳参数'
          : 'The service does not support the required output format or timestamps',
    SpeechTranscriptionErrorKind.payloadTooLarge =>
      zh ? '音频超过服务的大小限制' : 'The audio exceeds the service size limit',
    SpeechTranscriptionErrorKind.cancelled => zh ? '已取消' : 'Cancelled',
    SpeechTranscriptionErrorKind.emptyResult =>
      zh
          ? '服务没有返回可识别的语音文本'
          : 'The service returned no recognizable speech',
    _ => providerErrorCodeText(error.kind.name, zh),
  };
}
