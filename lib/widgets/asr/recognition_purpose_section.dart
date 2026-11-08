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
import '../../providers/offline_asr_settings_provider.dart';
import '../../providers/recognition_settings_provider.dart';
import '../../providers/speech_capability_provider.dart';
import '../../providers/speech_configuration_provider.dart';
import '../../services/asr/asr_model_manager.dart';
import '../../services/speech/practice_online_transcriber.dart';
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
          child: Text(
            MaterialLocalizations.of(dialogContext).cancelButtonLabel,
          ),
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

/// 在线方式不可选的原因说明；直接回答「还缺哪一步」。
String practiceOnlineBlockReasonText(
  AppLocalizations l10n,
  PracticeOnlineAccessDenial denial,
) => switch (denial) {
  PracticeOnlineAccessDenial.missingConfiguration =>
    l10n.recognitionOnlineNeedsConfiguration,
  PracticeOnlineAccessDenial.uploadNoticeMissing =>
    l10n.recognitionOnlineNeedsUploadNotice,
  PracticeOnlineAccessDenial.capabilityUnverified =>
    l10n.recognitionOnlineNeedsVerification,
  PracticeOnlineAccessDenial.capabilityNotSuitable =>
    l10n.recognitionOnlineNeedsSuitableModel,
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

/// 用途行状态的语气：只决定状态点的颜色，文案本身由 [recognitionPurposeStatus] 给出。
enum RecognitionStatusTone {
  /// 现在就能用。
  ready,

  /// 还缺一步（未下载、下载中、尚未验证）。
  pending,

  /// 当前不可用（下载失败、未配置、模型不适配）。
  blocked,
}

/// 用途行的状态：本机看该用途自己档位的安装状态，系统看平台自带能力，在线看该用途
/// 自己的能力验证结论（字幕要片段时间戳，跟读与复述要文本）。
({RecognitionStatusTone tone, String text}) recognitionPurposeStatus(
  AppLocalizations l10n,
  RecognitionSelection selection, {
  required AsrModelState localModelState,
  required PracticeOnlineAccessDenial? onlineBlockReason,
}) {
  switch (selection.mode) {
    case RecognitionMode.system:
      return (
        tone: RecognitionStatusTone.ready,
        text: l10n.recognitionStatusSystemBuiltIn,
      );
    case RecognitionMode.online:
      return switch (onlineBlockReason) {
        null => (
          tone: RecognitionStatusTone.ready,
          text: l10n.recognitionStatusOnlineVerified,
        ),
        PracticeOnlineAccessDenial.missingConfiguration => (
          tone: RecognitionStatusTone.blocked,
          text: l10n.speechProviderStatusUnconfigured,
        ),
        PracticeOnlineAccessDenial.capabilityNotSuitable => (
          tone: RecognitionStatusTone.blocked,
          text: l10n.recognitionStatusOnlineUnavailable,
        ),
        // 尚未验证与未告知都还没有该用途的能力结论。
        PracticeOnlineAccessDenial.capabilityUnverified ||
        PracticeOnlineAccessDenial.uploadNoticeMissing => (
          tone: RecognitionStatusTone.pending,
          text: l10n.speechCapabilityUnverified,
        ),
      };
    case RecognitionMode.local:
      return switch (localModelState.downloadStatus) {
        AsrModelDownloadStatus.downloaded => (
          tone: RecognitionStatusTone.ready,
          text: l10n.recognitionStatusLocalDownloaded,
        ),
        AsrModelDownloadStatus.downloading => (
          tone: RecognitionStatusTone.pending,
          text: l10n.recognitionStatusLocalDownloading,
        ),
        AsrModelDownloadStatus.failed => (
          tone: RecognitionStatusTone.blocked,
          text: l10n.recognitionStatusLocalDownloadFailed,
        ),
        AsrModelDownloadStatus.notDownloaded => (
          tone: RecognitionStatusTone.pending,
          text: l10n.recognitionStatusLocalNotDownloaded,
        ),
      };
  }
}

/// 一个用途行：用途名、方式与模型摘要、当前状态，点开只改该用途。
class _PurposeRow extends StatelessWidget {
  const _PurposeRow({
    required this.l10n,
    required this.theme,
    required this.purpose,
    required this.selection,
    required this.onlineModelId,
    required this.localModelState,
    required this.onlineBlockReason,
    required this.onTap,
  });

  final AppLocalizations l10n;
  final ThemeData theme;
  final RecognitionPurpose purpose;
  final RecognitionSelection selection;
  final String onlineModelId;
  final AsrModelState localModelState;
  final PracticeOnlineAccessDenial? onlineBlockReason;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = recognitionPurposeStatus(
      l10n,
      selection,
      localModelState: localModelState,
      onlineBlockReason: onlineBlockReason,
    );
    return ListTile(
      title: Text(recognitionPurposeLabel(l10n, purpose)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            recognitionSelectionSummary(
              l10n,
              selection,
              onlineModelId: onlineModelId,
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          _PurposeStatusLabel(status: status),
        ],
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// 状态文字加点状标记，不只靠颜色区分。
class _PurposeStatusLabel extends StatelessWidget {
  const _PurposeStatusLabel({required this.status});

  final ({RecognitionStatusTone tone, String text}) status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dotColor = switch (status.tone) {
      RecognitionStatusTone.ready => AppTheme.successColor,
      RecognitionStatusTone.pending => theme.colorScheme.onSurfaceVariant,
      RecognitionStatusTone.blocked => theme.colorScheme.error,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          status.text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 三个用途的识别选择列表。
class RecognitionPurposeSection extends ConsumerWidget {
  const RecognitionPurposeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(recognitionSettingsProvider);
    final asrState = ref.watch(offlineAsrSettingsProvider);
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
            _PurposeRow(
              l10n: l10n,
              theme: theme,
              purpose: purpose,
              selection: settings.forPurpose(purpose),
              onlineModelId: speechConfig?.onlineModelFor(purpose) ?? '',
              localModelState: asrState.modelStateOf(
                settings.forPurpose(purpose).localModelId,
              ),
              onlineBlockReason: ref.watch(
                onlineModeBlockReasonProvider(purpose),
              ),
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
            onlineAvailable: onlineAvailable,
          );
          // 在线不可选时仍展示该方式并说明缺什么，避免用户以为只能本机识别。
          final onlineBlocked = !modes.contains(RecognitionMode.online)
              ? innerRef.watch(onlineModeBlockReasonProvider(purpose))
              : null;
          final showOnlineRow = modes.length > 1 || onlineBlocked != null;
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          recognitionPurposeLabel(l10n, purpose),
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.recognitionPurposeScopeNote,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (showOnlineRow)
                    RadioGroup<RecognitionMode>(
                      groupValue: selection.mode,
                      onChanged: (mode) {
                        if (mode == null || mode == selection.mode) return;
                        applyRecognitionSelectionChange(
                          innerContext,
                          innerRef,
                          purpose: purpose,
                          selection: switch (mode) {
                            RecognitionMode.system => RecognitionSelection(
                              mode: RecognitionMode.system,
                              localModelId: selection.localModelId,
                            ),
                            RecognitionMode.online =>
                              RecognitionSelection.online(
                                localModelId: selection.localModelId,
                              ),
                            RecognitionMode.local => RecognitionSelection.local(
                              selection.localModelId,
                            ),
                          },
                        );
                      },
                      child: Column(
                        children: [
                          for (final mode in modes)
                            if (mode != RecognitionMode.online)
                              RadioListTile<RecognitionMode>(
                                value: mode,
                                title: Text(recognitionModeLabel(l10n, mode)),
                              ),
                          if (onlineBlocked != null)
                            RadioListTile<RecognitionMode>(
                              value: RecognitionMode.online,
                              enabled: false,
                              title: Text(
                                recognitionModeLabel(
                                  l10n,
                                  RecognitionMode.online,
                                ),
                              ),
                              subtitle: Text(
                                practiceOnlineBlockReasonText(
                                  l10n,
                                  onlineBlocked,
                                ),
                              ),
                            )
                          else
                            RadioListTile<RecognitionMode>(
                              value: RecognitionMode.online,
                              title: Text(
                                recognitionModeLabel(
                                  l10n,
                                  RecognitionMode.online,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  // 字幕在线模型与 Key 只在「在线语音服务」配置，这里直接指路。
                  if (purpose == RecognitionPurpose.subtitle)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.m,
                        AppSpacing.s,
                        AppSpacing.m,
                        AppSpacing.s,
                      ),
                      child: Text(
                        l10n.subtitleOnlineModelSettingsHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (selection.usesLocalModel) ...[
                    const Divider(height: 1),
                    RadioGroup<String>(
                      groupValue: selection.localModelId,
                      onChanged: (modelId) {
                        if (modelId == null ||
                            modelId == selection.localModelId) {
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
