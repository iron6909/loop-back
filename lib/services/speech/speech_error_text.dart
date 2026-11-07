/// 在线语音失败的用户文案；只显示分类，不展示响应原文或凭据。
///
/// 与文字 AI 共享同一套既有分类文案（鉴权、余额、地址/模型、限流、超时、服务、
/// 网络），只额外补充语音特有的分类，避免两套说法不一致。
library;

import 'package:flutter/widgets.dart';

import '../provider/provider_error_text.dart';
import 'shadowing_online_transcriber.dart';
import 'speech_transcription_client.dart';

String speechErrorText(BuildContext context, Object error) {
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  if (error is ShadowingRecordingRejected) {
    return switch (error.rejection) {
      ShadowingRecordingRejection.fileMissing =>
        zh ? '没有找到可上传的录音文件' : 'The recording file was not found',
      ShadowingRecordingRejection.unsupportedFormat =>
        zh
            ? '录音格式不受支持，无法上传'
            : 'The recording format is not supported for upload',
      ShadowingRecordingRejection.emptyAudio =>
        zh ? '录音没有可用的人声内容' : 'The recording contains no usable speech',
      ShadowingRecordingRejection.tooLong =>
        zh
            ? '录音超过单次在线转写时长上限，长录音将在后续版本支持'
            : 'The recording exceeds the single-request limit; long recordings come later',
      ShadowingRecordingRejection.tooLarge =>
        zh
            ? '录音超过单次上传大小上限，长录音将在后续版本支持'
            : 'The recording exceeds the single-upload size limit; long recordings come later',
    };
  }
  if (error is ShadowingOnlineAccessDenied) {
    return switch (error.reason) {
      ShadowingOnlineAccessDenial.missingConfiguration =>
        zh
            ? '在线语音未配置服务地址或 Key，请前往设置 → 语音识别'
            : 'Online speech has no service address or key. Open Settings → Speech recognition',
      ShadowingOnlineAccessDenial.uploadNoticeMissing =>
        zh
            ? '首次上传录音前需先确认上传告知，请前往设置 → 在线语音服务'
            : 'Confirm the upload notice in Settings → Online speech before the first upload',
      ShadowingOnlineAccessDenial.capabilityUnverified =>
        zh
            ? '跟读的在线模型尚未通过文本能力验证，请先在设置里验证'
            : 'Verify the shadowing online model in Settings before transcribing',
    };
  }
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
