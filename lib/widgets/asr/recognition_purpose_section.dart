/// 按用途（字幕 / 跟读 / 复述）的识别选择界面与变更守卫。
///
/// 界面只列出当前平台与用途真正可执行的方式：在线方式要等对应业务切片完成，
/// 系统识别只在支持的平台与用途出现。修改选择前若存在受影响的在途任务，先告知
/// 用户；拒绝则保留原配置与任务，接受才取消这些任务并应用变更。语音服务配置的
/// 保存复用同一套告知（[confirmCancelInFlightTasks]）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/recognition_selection.dart';
import '../../providers/recognition_settings_provider.dart';
import '../../providers/speech_capability_provider.dart';
import '../../providers/speech_configuration_provider.dart';
import '../../services/asr/asr_model_manager.dart';
import '../../theme/app_theme.dart';

/// 应用某用途的识别选择变更。
///
/// 返回是否已应用；用户在确认提示里拒绝时返回 false，配置与在途任务都保持原样。
Future<bool> applyRecognitionSelectionChange(
  BuildContext context,
  WidgetRef ref, {
  required RecognitionPurpose purpose,
  required RecognitionSelection selection,
}) async {
  final notifier = ref.read(recognitionSettingsProvider.notifier);
  final first = await notifier.change(purpose: purpose, selection: selection);
  final affected = first.affectedTasks;
  if (first.applied || affected == null || affected.isEmpty) {
    return first.applied;
  }
  if (!context.mounted) return false;
  if (!await confirmCancelInFlightTasks(context, affected)) return false;
  final second = await notifier.change(
    purpose: purpose,
    selection: selection,
    cancelInFlight: true,
  );
  return second.applied;
}

/// 变更前告知：有受影响的在途任务时询问是否取消它们。
///
/// 识别设置与语音服务配置共用这一处提示，拒绝返回 false，调用方保持原配置与
/// 任务不动。
Future<bool> confirmCancelInFlightTasks(
  BuildContext context,
  List<RecognitionInFlightTask> affected,
) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.recognitionChangeTitle),
      content: Text(l10n.recognitionChangeMessage(affected.length)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.recognitionChangeConfirm),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// 用途名称。
String recognitionPurposeLabel(
  AppLocalizations l10n,
  RecognitionPurpose purpose,
) => switch (purpose) {
  RecognitionPurpose.subtitle => l10n.recognitionPurposeSubtitle,
  RecognitionPurpose.shadowing => l10n.recognitionPurposeShadowing,
  RecognitionPurpose.retell => l10n.recognitionPurposeRetell,
};

/// 方式名称。
String recognitionModeLabel(AppLocalizations l10n, RecognitionMode mode) =>
    switch (mode) {
      RecognitionMode.local => l10n.recognitionModeLocal,
      RecognitionMode.system => l10n.recognitionModeSystem,
      RecognitionMode.online => l10n.recognitionModeOnline,
    };

/// 当前选择的一行摘要：方式（本机带本地模型名，在线带在线模型 id）。
String recognitionSelectionSummary(
  AppLocalizations l10n,
  RecognitionSelection selection, {
  String onlineModelId = '',
}) {
  if (selection.usesOnlineModel) {
    return onlineModelId.isEmpty
        ? recognitionModeLabel(l10n, selection.mode)
        : l10n.recognitionOnlineModelSummary(onlineModelId);
  }
  if (!selection.usesLocalModel) {
    return recognitionModeLabel(l10n, selection.mode);
  }
  final model = availableModels
      .where((candidate) => candidate.id == selection.localModelId)
      .firstOrNull;
  return '${recognitionModeLabel(l10n, selection.mode)} · '
      '${model?.displayName ?? selection.localModelId}';
}

/// 三个用途的识别选择列表。
class RecognitionPurposeSection extends ConsumerWidget {
  const RecognitionPurposeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(recognitionSettingsProvider);
    final speechConfig = ref
        .watch(speechConfigurationProvider)
        .valueOrNull
        ?.config;
    final theme = Theme.of(context);
    return Card(
      child: Column(
        children: [
          for (final purpose in RecognitionPurpose.values) ...[
            if (purpose != RecognitionPurpose.values.first)
              const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              title: Text(recognitionPurposeLabel(l10n, purpose)),
              subtitle: Text(
                recognitionSelectionSummary(
                  l10n,
                  settings.forPurpose(purpose),
                  onlineModelId:
                      speechConfig?.onlineModelFor(purpose) ?? '',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openPurposeSheet(context, ref, purpose),
            ),
          ],
        ],
      ),
    );
  }

  /// 打开某用途的方式与模型选择面板。
  Future<void> _openPurposeSheet(
    BuildContext context,
    WidgetRef ref,
    RecognitionPurpose purpose,
  ) {
    final systemSupported = ref.read(systemRecognitionPlatformProvider);
    final onlineSubtitleAvailable = ref.read(
      onlineSubtitleAvailableProvider,
    );
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Consumer(
        builder: (innerContext, innerRef, _) {
          final l10n = AppLocalizations.of(innerContext)!;
          final selection = innerRef
              .watch(recognitionSettingsProvider)
              .forPurpose(purpose);
          // 在线是否可选取决于 Key、上传告知与该用途自己的文本能力验证。
          final onlineAvailable =
              innerRef
                  .watch(onlinePracticeAvailabilityProvider(purpose))
                  .valueOrNull ??
              false;
          final modes = availableRecognitionModes(
            purpose,
            systemSupported: systemSupported,
            onlineSubtitleAvailable: onlineSubtitleAvailable,
            onlineAvailable: onlineAvailable,
          );
          final theme = Theme.of(innerContext);
          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.m,
                      0,
                      AppSpacing.m,
                      AppSpacing.s,
                    ),
                    child: Text(
                      recognitionPurposeLabel(l10n, purpose),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (modes.length > 1)
                    RadioGroup<RecognitionMode>(
                      groupValue: selection.mode,
                      onChanged: (mode) {
                        if (mode == null || mode == selection.mode) return;
                        applyRecognitionSelectionChange(
                          innerContext,
                          innerRef,
                          purpose: purpose,
                          selection: switch (mode) {
                            RecognitionMode.system =>
                              RecognitionSelection(
                                mode: RecognitionMode.system,
                                localModelId: selection.localModelId,
                              ),
                            RecognitionMode.online =>
                              RecognitionSelection.online(
                                localModelId: selection.localModelId,
                              ),
                            RecognitionMode.local =>
                              RecognitionSelection.local(
                                selection.localModelId,
                              ),
                          },
                        );
                      },
                      child: Column(
                        children: [
                          for (final mode in modes)
                            RadioListTile<RecognitionMode>(
                              value: mode,
                              title: Text(recognitionModeLabel(l10n, mode)),
                            ),
                        ],
                      ),
                    ),
                  if (selection.usesLocalModel) ...[
                    const Divider(height: 1),
                    RadioGroup<String>(
                      groupValue: selection.localModelId,
                      onChanged: (modelId) {
                        if (modelId == null || modelId == selection.localModelId) {
                          return;
                        }
                        applyRecognitionSelectionChange(
                          innerContext,
                          innerRef,
                          purpose: purpose,
                          selection: RecognitionSelection.local(modelId),
                        );
                      },
                      child: Column(
                        children: [
                          for (final model in availableModels)
                            RadioListTile<String>(
                              value: model.id,
                              title: Text(model.displayName),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
