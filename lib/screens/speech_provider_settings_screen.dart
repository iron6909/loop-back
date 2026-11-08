/// 在线语音服务独立页。
///
/// 供应商、根地址、Key、三个用途的在线模型与能力验证集中在这一页；打开页面与
/// 保存配置都不发网络请求，只有用户点「获取转写模型」或「验证模型」才发请求。
/// 页首整体状态与语音识别页的入口行共用 [speechProviderStatusText]，不各写一套。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../providers/speech_capability_provider.dart';
import '../providers/speech_configuration_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/asr/speech_provider_section.dart';

/// 在线语音服务页。
class SpeechProviderSettingsScreen extends ConsumerWidget {
  const SpeechProviderSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final state =
        ref.watch(speechConfigurationProvider).valueOrNull ??
        const SpeechConfigurationState();
    final capabilities =
        ref.watch(speechCapabilityProvider).valueOrNull ??
        const SpeechCapabilityState();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.speechProviderTitle)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.m),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s,
              0,
              AppSpacing.s,
              AppSpacing.s,
            ),
            child: Text(
              l10n.speechProviderDescription,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          // 整体状态放在页首，配置卡片内不再重复标题行。
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s,
              0,
              AppSpacing.s,
              AppSpacing.m,
            ),
            child: Text(
              speechProviderStatusText(l10n, state, capabilities),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: state.isConfigured
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.error,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SpeechProviderSection(),
        ],
      ),
    );
  }
}
