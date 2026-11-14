/// 语音识别设置页。
///
/// 按「识别方式 → 本机模型 → 在线服务」三层组织：用途决定方式，本机模型只是
/// 资源库（下载、占用与用途标签），在线服务只保留一条入口。页面级后端单选已
/// 删除：[AsrBackend] 由跟读用途的本机 / 系统选择驱动，Android 固定本机。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/recognition_selection.dart';
import '../providers/offline_asr_settings_provider.dart';
import '../providers/asr_model_installation_provider.dart';
import '../providers/recognition_settings_provider.dart';
import '../providers/speech_capability_provider.dart';
import '../providers/speech_configuration_provider.dart';
import '../services/asr/asr_model_manager.dart';
import '../services/asr/offline_asr_engine.dart';
import '../theme/app_theme.dart';
import '../utils/download_failure_message.dart';
import '../widgets/asr/asr_download_source_presentation.dart';
import '../widgets/asr/recognition_purpose_section.dart';
import '../widgets/asr/speech_provider_section.dart';
import 'speech_provider_settings_screen.dart';

/// 语音识别设置页。
class AsrSettingsScreen extends ConsumerStatefulWidget {
  const AsrSettingsScreen({super.key});

  @override
  ConsumerState<AsrSettingsScreen> createState() => _AsrSettingsScreenState();
}

class _AsrSettingsScreenState extends ConsumerState<AsrSettingsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(asrModelInstallationGateProvider)
          .ensureInstallationStatesLoaded();
      final state = ref.read(offlineAsrSettingsProvider);
      if (state.enabled &&
          state.backend == AsrBackend.offline &&
          state.downloadStatus == AsrModelDownloadStatus.failed &&
          !state.isDownloading) {
        ref.read(offlineAsrSettingsProvider.notifier).retryDownload();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(offlineAsrSettingsProvider);
    final speechState =
        ref.watch(speechConfigurationProvider).valueOrNull ??
        const SpeechConfigurationState();
    final speechCapabilities =
        ref.watch(speechCapabilityProvider).valueOrNull ??
        const SpeechCapabilityState();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.speechRecognition)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.m),
        children: [
          // 全页只保留一条说明文字，放在「识别方式」分组之前。
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s,
              0,
              AppSpacing.s,
              AppSpacing.m,
            ),
            child: Text(
              l10n.recognitionPurposeDescription,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),

          _SectionLabel(text: l10n.recognitionModeTitle),
          const RecognitionPurposeSection(),

          // 本机模型是资源库：跟读使用系统识别时仍可下载、删除模型。
          _SectionLabel(
            text: l10n.localModelLibraryTitle,
            trailing: _buildLibraryHeader(l10n, state, theme),
          ),
          Card(child: Column(children: [_buildModelList(l10n, state, theme)])),

          // 在线服务分组只有一行入口，具体配置在独立的「在线语音服务」页。
          const SizedBox(height: AppSpacing.m),
          _SectionLabel(text: l10n.onlineServiceSectionTitle),
          _buildOnlineServiceEntry(
            l10n,
            theme,
            speechState,
            speechCapabilities,
          ),
        ],
      ),
    );
  }

  // ========== 在线语音服务入口 ==========

  /// 在线服务入口行：只显示服务类型与整体状态，具体配置在独立页。
  ///
  /// 状态文案与独立页共用 [speechProviderStatusText]；主页面不发任何网络请求。
  Widget _buildOnlineServiceEntry(
    AppLocalizations l10n,
    ThemeData theme,
    SpeechConfigurationState speechState,
    SpeechCapabilityState speechCapabilities,
  ) {
    final config = speechState.config;
    return Card(
      child: ListTile(
        leading: Icon(
          Icons.cloud_outlined,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(l10n.speechProviderTitle),
        subtitle: Text(
          speechProviderStatusText(l10n, speechState, speechCapabilities),
          style: theme.textTheme.bodySmall?.copyWith(
            color: speechProviderStatusColor(theme, speechState),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (config != null)
              Text(
                speechProviderKindText(l10n, config.kind),
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            const SizedBox(width: AppSpacing.xs),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const SpeechProviderSettingsScreen(),
          ),
        ),
      ),
    );
  }

  // ========== 本机模型资源库 ==========

  /// 资源库标题右侧：已下载总占用与清理所有已下载模型的次要操作。
  ///
  /// 清理沿用既有确认文案与删除规则：跟读当前档位在本机后端下仍由
  /// [OfflineAsrSettingsNotifier.deleteModel] 保护。
  Widget _buildLibraryHeader(
    AppLocalizations l10n,
    OfflineAsrSettingsState state,
    ThemeData theme,
  ) {
    final totalBytes = state.totalDownloadedModelBytes;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.localModelLibraryTotal(_formatBytes(totalBytes)),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.delete_sweep_outlined),
          tooltip: l10n.localModelLibraryDeleteAll,
          onPressed: totalBytes > 0
              ? () => _confirmDeleteAllModels(context, l10n)
              : null,
        ),
      ],
    );
  }

  Widget _buildModelList(
    AppLocalizations l10n,
    OfflineAsrSettingsState state,
    ThemeData theme,
  ) {
    final settings = ref.watch(recognitionSettingsProvider);
    final rows = <Widget>[];
    for (var i = 0; i < availableModels.length; i++) {
      final model = availableModels[i];
      if (i > 0) {
        rows.add(const Divider(height: 1, indent: 16, endIndent: 16));
      }
      rows.add(_buildModelRow(l10n, theme, state, settings, model));
    }
    return Column(children: rows);
  }

  Widget _buildModelRow(
    AppLocalizations l10n,
    ThemeData theme,
    OfflineAsrSettingsState state,
    RecognitionSettings settings,
    AsrModelInfo model,
  ) {
    final modelState = state.modelStateOf(model.id);
    final isRecommended = state.recommendedModel.id == model.id;
    return ListTile(
      title: Row(
        children: [
          Flexible(child: Text(model.displayName)),
          if (isRecommended) ...[
            const SizedBox(width: 8),
            _RecommendedBadge(text: l10n.ttsModelRecommended, theme: theme),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _modelSubtitle(
            l10n,
            theme,
            model.id,
            modelState,
            state.downloadSource,
          ),
          _modelUsageTags(l10n, theme, settings, model.id),
        ],
      ),
      trailing: _modelTrailing(
        l10n,
        model.id,
        modelState,
        isSelected: state.selectedModel.id == model.id,
        backend: state.backend,
      ),
    );
  }

  /// 用途标签只标记「方式为本机且档位匹配」的用途，系统与在线不占用本机模型。
  Widget _modelUsageTags(
    AppLocalizations l10n,
    ThemeData theme,
    RecognitionSettings settings,
    String modelId,
  ) {
    final usedBy = [
      for (final purpose in RecognitionPurpose.values)
        if (settings.forPurpose(purpose).usesLocalModel &&
            settings.forPurpose(purpose).localModelId == modelId)
          purpose,
    ];
    if (usedBy.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          for (final purpose in usedBy)
            _UsageTag(
              text: l10n.localModelUsageTag(
                recognitionPurposeLabel(l10n, purpose),
              ),
              theme: theme,
            ),
        ],
      ),
    );
  }

  Widget _modelSubtitle(
    AppLocalizations l10n,
    ThemeData theme,
    String modelId,
    AsrModelState state,
    AsrDownloadSource downloadSource,
  ) {
    final approxSize = _approxModelSizeText(l10n, modelId);
    final description = _modelDescription(l10n, modelId);
    final showApproxInDescription = !state.isReady;
    final children = <Widget>[
      Text(
        showApproxInDescription ? '$description $approxSize' : description,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        ),
      ),
    ];
    // 三档模型都已迁移到公开来源，展示来源与许可。
    final publicSpec = asrPublicResourceCatalog[modelId];
    if (publicSpec != null) {
      children.add(
        Text(
          l10n.asrModelSourceLine(
            asrDownloadSourceLabel(l10n, downloadSource),
            publicSpec.license,
          ),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
      );
    }
    if (state.isDownloading) {
      final pct = '${(state.downloadProgress * 100).toStringAsFixed(0)}%';
      children.add(const SizedBox(height: 6));
      children.add(LinearProgressIndicator(value: state.downloadProgress));
      children.add(const SizedBox(height: 2));
      children.add(Text(l10n.speechModelDownloading(pct)));
    } else if (state.downloadStatus == AsrModelDownloadStatus.failed) {
      children.add(
        Text(
          downloadFailureMessage(l10n, state.downloadError),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    } else if (state.isReady) {
      children.add(
        Text(
          l10n.speechModelReady(
            state.localSizeBytes > 0 ? _formatBytes(state.localSizeBytes) : '—',
          ),
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppTheme.successColor,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  /// 每行只保留与安装状态对应的动作：未下载下载、下载中取消、失败重试、已下载删除。
  ///
  /// 跟读当前档位在下本机后端下不可删除，与
  /// [OfflineAsrSettingsNotifier.deleteModel] 的保护一致；系统后端下它只是已下载
  /// 资源，与「删除所有已下载模型」一样可以删。下载中的档位仍不给取消入口。
  Widget? _modelTrailing(
    AppLocalizations l10n,
    String modelId,
    AsrModelState state, {
    required bool isSelected,
    required AsrBackend backend,
  }) {
    final protected =
        isSelected &&
        (state.isDownloading ||
            (state.isReady && backend == AsrBackend.offline));
    if (protected) return null;
    if (state.isDownloading) {
      return TextButton(
        onPressed: () => ref
            .read(offlineAsrSettingsProvider.notifier)
            .cancelDownload(modelId),
        child: Text(l10n.ttsCancelDownload),
      );
    }
    if (state.downloadStatus == AsrModelDownloadStatus.failed) {
      return TextButton(
        onPressed: () => ref
            .read(offlineAsrSettingsProvider.notifier)
            .retryDownload(modelId),
        child: Text(l10n.retryDownload),
      );
    }
    if (state.isReady) {
      return IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: l10n.deleteModelAction,
        onPressed: () =>
            _confirmDeleteModel(context, l10n, modelId, state.localSizeBytes),
      );
    }
    return TextButton(
      onPressed: () =>
          ref.read(offlineAsrSettingsProvider.notifier).downloadModel(modelId),
      child: Text(l10n.localModelDownloadAction),
    );
  }

  // ========== 确认与删除 ==========

  void _confirmDeleteModel(
    BuildContext context,
    AppLocalizations l10n,
    String modelId,
    int localSizeBytes,
  ) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteModelConfirmTitle),
        content: Text(
          l10n.deleteModelConfirmMessage(_formatBytes(localSizeBytes)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              ref
                  .read(offlineAsrSettingsProvider.notifier)
                  .deleteModel(modelId);
            },
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(l10n.deleteModelAction),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteAllModels(BuildContext context, AppLocalizations l10n) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteModelConfirmTitle),
        content: Text(l10n.asrDeleteAllModelsConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              ref
                  .read(offlineAsrSettingsProvider.notifier)
                  .deleteDownloadedModels(includeSelected: true);
            },
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(l10n.deleteModelAction),
          ),
        ],
      ),
    );
  }

  // ========== 工具方法 ==========

  static String _modelDescription(AppLocalizations l10n, String modelId) {
    if (modelId.contains('tiny')) return l10n.asrModelFastDescription;
    if (modelId.contains('base')) return l10n.asrModelBalancedDescription;
    if (modelId.contains('small')) return l10n.asrModelAccurateDescription;
    return l10n.asrBackendLocalWhisperDescription;
  }

  static String _approxModelSizeText(AppLocalizations l10n, String modelId) {
    final publicSpec = asrPublicResourceCatalog[modelId];
    if (publicSpec == null) return '';
    return l10n.speechModelApproxSize(
      _formatBytes(publicSpec.estimatedDownloadBytes),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
}

/// 分组小标题，与语音合成设置页保持一致。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.m,
        AppSpacing.s,
        AppSpacing.m,
        AppSpacing.s,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (trailing case final trailing?) trailing,
        ],
      ),
    );
  }
}

class _RecommendedBadge extends StatelessWidget {
  const _RecommendedBadge({required this.text, required this.theme});

  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 用途标签：哪个用途当前正以本机方式使用这个档位。
class _UsageTag extends StatelessWidget {
  const _UsageTag({required this.text, required this.theme});

  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
