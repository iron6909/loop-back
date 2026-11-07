/// 本机转录选项：英语、独立模型档位和短句合并偏好。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_localizations.dart';
import '../models/recognition_selection.dart';
import '../providers/offline_asr_settings_provider.dart';
import '../providers/recognition_settings_provider.dart';
import '../providers/settings_provider.dart';
import '../services/asr/asr_model_manager.dart';
import 'asr/recognition_purpose_section.dart';

/// 与既有偏好共用同一来源，弹窗不再维护一份镜像。
final transcriptionMergeEnabledProvider = Provider<bool>(
  (ref) => ref.watch(
    appSettingsProvider.select((s) => s.aiTranscriptionAutoMergeEnabled),
  ),
);

class TranscriptionOptions extends ConsumerWidget {
  const TranscriptionOptions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final selection = ref.watch(recognitionSettingsProvider).subtitle;
    final settings = ref.watch(offlineAsrSettingsProvider);
    return Column(
      children: [
        Text(l10n.transcriptionTimingNotice),
        ListTile(
          title: Text(l10n.selectLanguage),
          trailing: PopupMenuButton<String>(
            tooltip: '',
            initialValue: 'en',
            itemBuilder: (_) => [
              PopupMenuItem(value: 'en', child: Text(l10n.languageEnglish)),
            ],
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(l10n.languageEnglish),
            ),
          ),
        ),
        ListTile(
          title: Text(l10n.transcriptionModelTier),
          subtitle: Text(recognitionModeLabel(l10n, selection.mode)),
          trailing: PopupMenuButton<String>(
            tooltip: '',
            initialValue: selection.localModelId,
            // 与设置页共用同一份字幕用途状态，不在弹窗里维护镜像。
            onSelected: (id) => applyRecognitionSelectionChange(
              context,
              ref,
              purpose: RecognitionPurpose.subtitle,
              selection: RecognitionSelection.local(id),
            ),
            itemBuilder: (_) => [
              for (final model in availableModels)
                PopupMenuItem(
                  value: model.id,
                  child: Text(
                    '${model.displayName} · ${settings.modelStateOf(model.id).isReady ? l10n.speechModelStatusReady : l10n.speechModelStatusNeedsDownload}',
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                availableModels
                        .where((model) => model.id == selection.localModelId)
                        .firstOrNull
                        ?.displayName ??
                    selection.localModelId,
              ),
            ),
          ),
        ),
        SwitchListTile(
          title: Text(l10n.autoMergeShortSentences),
          subtitle: Text(l10n.autoMergeShortSentencesHint),
          value: ref.watch(transcriptionMergeEnabledProvider),
          onChanged: (value) => ref
              .read(appSettingsProvider.notifier)
              .setAiTranscriptionAutoMergeEnabled(value),
        ),
      ],
    );
  }
}
