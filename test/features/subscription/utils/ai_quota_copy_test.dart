/// AI 额度提示文案映射测试。
library;

import 'package:loop_back/features/subscription/models/premium_feature.dart';
import 'package:loop_back/features/subscription/models/ai_quota_rejection.dart';
import 'package:loop_back/features/subscription/utils/ai_quota_copy.dart';
import 'package:loop_back/l10n/app_localizations_en.dart';
import 'package:loop_back/l10n/app_localizations_zh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('每个 AI 功能都生成对应的中文额度用尽标题', () {
    final l10n = AppLocalizationsZh();
    final expected = <PremiumFeature, String>{
      PremiumFeature.aiTranslation: '本月 AI 翻译免费额度已用完',
      PremiumFeature.aiAnalysis: '本月 AI 句子解析免费额度已用完',
      PremiumFeature.aiSenseGroup: '本月 AI 句子意群拆分免费额度已用完',
      PremiumFeature.aiWordAnalysis: '本月 AI 词汇解析免费额度已用完',
      PremiumFeature.aiTranscription: '本月 AI 转录免费额度已用完',
      PremiumFeature.aiChat: '本月 AI 助手免费额度已用完',
      PremiumFeature.aiRetellReview: '本月 AI 复述评估免费额度已用完',
    };

    for (final entry in expected.entries) {
      expect(aiQuotaExceededTitleFor(l10n, entry.key), entry.value);
    }
  });

  test('英文标题与无功能标识的兼容兜底', () {
    final l10n = AppLocalizationsEn();

    expect(
      aiQuotaExceededTitleFor(l10n, PremiumFeature.aiTranscription),
      "This month's free AI subtitle transcription quota is used up",
    );
    expect(
      aiQuotaExceededTitleFor(l10n, null),
      "This month's free AI quota is used up",
    );
  });

  test('免费版禁用态按功能生成中英文标题与说明', () {
    final zh = AppLocalizationsZh();
    final en = AppLocalizationsEn();

    expect(
      aiQuotaTitleFor(
        zh,
        PremiumFeature.aiTranslation,
        AiQuotaRejectionReason.unsupportedForFreePlan,
      ),
      '免费版暂不支持 AI 翻译',
    );
    expect(
      aiQuotaMessageFor(zh, AiQuotaRejectionReason.unsupportedForFreePlan),
      '升级会员，解锁该功能和更多 AI 功能。',
    );
    expect(
      aiQuotaTitleFor(
        en,
        PremiumFeature.aiChat,
        AiQuotaRejectionReason.unsupportedForFreePlan,
      ),
      "The free plan doesn't support AI assistant",
    );
    expect(
      aiQuotaTitleFor(zh, null, AiQuotaRejectionReason.unsupportedForFreePlan),
      '免费版暂不支持此 AI 功能',
    );
  });
}
