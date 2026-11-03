/// AI 入口的供应商错误文案；仅显示安全分类，不展示响应原文或凭据。
library;

import 'package:flutter/widgets.dart';
import 'provider_config.dart';
import 'provider_http_client.dart';

String providerErrorText(BuildContext context, Object error) {
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  if (error is ProviderNotConfiguredException) {
    return zh
    ? '尚未配置 AI 服务，请前往设置 → AI 服务填写供应商与 API Key'
    : 'Configure a provider and API key in Settings → AI service';
  }
  return providerErrorCodeText(error is ProviderHttpException ? error.kind.name : 'invalidResponse', zh);
}

String providerErrorCodeText(String? code, bool zh) => switch (code) {
  'not_configured' => zh ? '请先在设置 → AI 服务配置供应商' : 'Configure AI service in Settings first',
  'invalidRequest' => zh ? '供应商不接受当前请求，请检查模型或接口兼容性' : 'Provider rejected the request. Check model or API compatibility',
  'unauthorized' => zh ? 'API Key 无效或未授权，请检查供应商设置' : 'API key is invalid or unauthorized',
  'insufficientBalance' => zh ? '供应商余额或套餐不足' : 'Provider balance or plan is insufficient',
  'notFound' => zh ? '供应商地址或模型不存在' : 'Provider address or model was not found',
  'rateLimited' => zh ? '供应商限流，请稍后重试' : 'Provider rate limit reached. Try again later',
  'timeout' => zh ? '供应商请求超时，请重试' : 'Provider request timed out. Try again',
  'serverError' => zh ? '供应商服务暂不可用，请稍后重试' : 'Provider is temporarily unavailable',
  'network' => zh ? '无法连接供应商，请检查网络' : 'Cannot connect to provider. Check your network',
  'transcription_failed' => zh ? '本机转写失败，请检查英语识别模型后重试' : 'Local transcription failed. Check the English speech model',
  _ => zh ? 'AI 返回的结果无效，请重试' : 'AI returned an invalid result. Try again',
};
