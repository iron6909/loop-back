/// 在线语音失败的用户文案；只显示分类，不展示响应原文或凭据。
///
/// 与文字 AI 共享同一套既有分类文案（鉴权、余额、地址/模型、限流、超时、服务、
/// 网络），只额外补充语音特有的分类，避免两套说法不一致。
///
/// 这些文案按当前语言分支就地维护、不迁 ARB：整套分类的唯一来源是
/// `providerErrorCodeText(code, zh)`，它不依赖 BuildContext（[speechCostText]
/// 同样只收 bool）；只把语音这一半迁走会让同一分类在 ARB 与代码里各存一份。
library;

import 'package:flutter/widgets.dart';

import '../provider/provider_error_text.dart';
import 'practice_chunk_transcriber.dart';
import 'practice_online_transcriber.dart';
import 'speech_transcription_client.dart';

String speechErrorText(BuildContext context, Object error) {
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  if (error is PracticeChunkFailure) {
    return switch (error.reason) {
      PracticeChunkFailureReason.noSpeech =>
        zh ? '录音里没有可识别的语音' : 'The recording contains no recognizable speech',
      PracticeChunkFailureReason.decodeFailed =>
        zh ? '无法读取这段录音的音频内容' : 'The recording audio could not be read',
      PracticeChunkFailureReason.configChanged =>
        zh ? '语音配置已变化，请重新转写' : 'Speech settings changed; transcribe again',
      PracticeChunkFailureReason.cancelled => zh ? '已取消' : 'Cancelled',
      // 供应商失败按既有分类显示具体原因（超时、网络、鉴权……）。
      PracticeChunkFailureReason.requestFailed => switch (error.cause) {
        final cause? => speechErrorText(context, cause),
        null => providerErrorCodeText('invalidResponse', zh),
      },
    };
  }
  if (error is PracticeRecordingRejected) {
    return switch (error.rejection) {
      PracticeRecordingRejection.fileMissing =>
        zh ? '没有找到可上传的录音文件' : 'The recording file was not found',
      PracticeRecordingRejection.unsupportedFormat =>
        zh
            ? '录音格式不受支持，无法上传'
            : 'The recording format is not supported for upload',
      PracticeRecordingRejection.emptyAudio =>
        zh ? '录音没有可用的人声内容' : 'The recording contains no usable speech',
    };
  }
  if (error is PracticeOnlineAccessDenied) {
    return switch (error.reason) {
      PracticeOnlineAccessDenial.missingConfiguration =>
        zh
            ? '在线语音未配置服务地址，请前往设置 → 语音识别 → 在线语音服务'
            : 'Online speech has no service address. Open Settings → Speech recognition → Online speech service',
      PracticeOnlineAccessDenial.missingApiKey =>
        zh
            ? '在线语音缺少 API Key，请前往设置 → 语音识别 → 在线语音服务'
            : 'Online speech has no API key. Open Settings → Speech recognition → Online speech service',
      PracticeOnlineAccessDenial.missingOnlineModel =>
        zh
            ? '该用途还没有在线模型，请前往设置 → 语音识别 → 在线语音服务填写'
            : 'This purpose has no online model. Open Settings → Speech recognition → Online speech service',
      PracticeOnlineAccessDenial.uploadNoticeMissing =>
        zh
            ? '首次上传录音前需先确认上传告知，请前往设置 → 在线语音服务'
            : 'Confirm the upload notice in Settings → Online speech before the first upload',
      PracticeOnlineAccessDenial.capabilityUnverified =>
        zh
            ? '跟读的在线模型尚未通过文本能力验证，请先在设置里验证'
            : 'Verify the shadowing online model in Settings before transcribing',
      PracticeOnlineAccessDenial.capabilityNotSuitable =>
        zh
            ? '该模型没有返回片段时间戳，不能用于字幕；请换一个支持时间戳的模型并重新验证'
            : 'This model returned no segment timestamps, so it cannot produce subtitles. Choose a model that supports timestamps and verify it',
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
      zh ? '服务没有返回可识别的语音文本' : 'The service returned no recognizable speech',
    _ => providerErrorCodeText(error.kind.name, zh),
  };
}

/// 在线语音的费用文案。
///
/// 只在供应商真的报告了本次费用时给出数字；[reportedCost] 为 null 表示未知，
/// 不能显示成免费或 0。复述与跟读共用这套说法，避免同一件事两种表达。
String speechCostText(bool zh, double? reportedCost) {
  if (reportedCost == null) {
    return zh ? '在线语音费用：未知' : 'Online speech cost: unknown';
  }
  return zh
      ? '在线语音费用：$reportedCost'
      : 'Online speech cost: $reportedCost';
}
