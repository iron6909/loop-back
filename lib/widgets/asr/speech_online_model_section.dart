/// 按用途在线模型区：一次获取转写模型目录，三个用途共用同一份列表。
///
/// 目录只存在于当前页面会话：供应商、根地址或 Key 变化后作废，迟到的结果按代次
/// 与挂载状态丢弃。获取是只读查询，不上传音频、不写能力记录；每个用途的能力
/// 验证只在用户点击后发生，保存与在途任务确认仍由外部传入的 [onSave] 负责。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/provider_settings/widgets/provider_input_dialog.dart';
import '../../l10n/app_localizations.dart';
import '../../models/recognition_selection.dart';
import '../../providers/speech_capability_provider.dart';
import '../../providers/speech_configuration_provider.dart';
import '../../services/speech/speech_capability.dart';
import '../../services/speech/speech_config.dart';
import '../../services/speech/speech_error_text.dart';
import '../../theme/app_theme.dart';
import 'recognition_purpose_section.dart' show recognitionPurposeLabel;

/// 按用途在线模型区，不含供应商、根地址与 Key 三行。
class SpeechOnlineModelSection extends ConsumerStatefulWidget {
  const SpeechOnlineModelSection({
    super.key,
    required this.saving,
    required this.onSave,
  });

  /// 连接配置正在保存：保存期间不并发修改在线模型。
  final bool saving;

  /// 选择或手填模型后走既有保存与在途任务确认，这里不复制保存逻辑。
  final Future<void> Function(SpeechConfig config) onSave;

  @override
  ConsumerState<SpeechOnlineModelSection> createState() =>
      _SpeechOnlineModelSectionState();
}

class _SpeechOnlineModelSectionState
    extends ConsumerState<SpeechOnlineModelSection> {
  /// 本页会话获取到的转写模型目录；null 表示尚未获取或列表已作废。
  /// 三个用途共用这一份列表。
  List<String>? _modelIds;

  /// 正在获取目录；加载中禁用重复点击。
  bool _fetchingModels = false;

  /// 目录失败或为空时的提示，显示在分区标题下方。
  String? _modelListMessage;

  /// 目录请求代次：配置变化或重新获取时递增，迟到的结果直接丢弃。
  int _catalogGeneration = 0;

  /// 验证失败的原因，显示在用途模型行下方。
  String? _error;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final state =
        ref.watch(speechConfigurationProvider).valueOrNull ??
        const SpeechConfigurationState();
    final capabilities =
        ref.watch(speechCapabilityProvider).valueOrNull ??
        const SpeechCapabilityState();
    final config = state.config;
    // 任何保存路径都经过配置 provider：它是目录作废的唯一触发来源。
    ref.listen(speechConfigurationProvider, _clearCatalogOnServiceChange);
    return Column(
      children: [
        _sectionHeader(l10n, config, state),
        for (final purpose in RecognitionPurpose.values) ...[
          const Divider(height: 1, indent: 16, endIndent: 16),
          _modelRow(l10n, config, state, capabilities, purpose),
        ],
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.m),
            child: Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }

  /// 分区标题「按用途在线模型」与页面级「获取转写模型」。
  ///
  /// 目录只对 OpenRouter 提供：自定义服务隐藏按钮，用途模型行直接手填；未保存
  /// 配置或缺 Key 时按钮保留但禁用，由状态行说明先补哪一步。
  Widget _sectionHeader(
    AppLocalizations l10n,
    SpeechConfig? config,
    SpeechConfigurationState state,
  ) {
    final theme = Theme.of(context);
    final canFetch =
        config != null &&
        state.hasApiKey &&
        !widget.saving &&
        !_fetchingModels;
    final status = _modelListStatusText(l10n, config, state);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.m,
        AppSpacing.s,
        AppSpacing.s,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.speechModelSectionTitle,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (config?.kind != SpeechProviderKind.custom)
                // 文字按钮保证不低于 44dp 的触控区域。
                TextButton(
                  onPressed: canFetch ? _fetchModels : null,
                  child: Text(l10n.speechModelFetch),
                ),
            ],
          ),
          if (status case final text?)
            Padding(
              padding: const EdgeInsets.only(
                right: AppSpacing.m,
                bottom: AppSpacing.s,
              ),
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _modelListMessage == null
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 分区状态行：加载中、已获取数量、失败或空列表，或还缺哪一步。
  ///
  /// 自定义服务没有目录接口，不显示获取前的说明。
  String? _modelListStatusText(
    AppLocalizations l10n,
    SpeechConfig? config,
    SpeechConfigurationState state,
  ) {
    if (config?.kind == SpeechProviderKind.custom) return null;
    if (_fetchingModels) return l10n.speechModelFetching;
    if (_modelListMessage case final message?) return message;
    if (_modelIds case final models?) {
      return l10n.speechModelFetched(models.length);
    }
    if (config == null) return l10n.speechModelFetchNeedsConfig;
    if (!state.hasApiKey) return l10n.speechModelFetchNeedsKey;
    return null;
  }

  /// 一个用途的在线模型行：已有目录时打开选择器，否则直接手填；
  /// 行尾文字按钮对已保存的模型做一次真实能力验证。
  Widget _modelRow(
    AppLocalizations l10n,
    SpeechConfig? config,
    SpeechConfigurationState state,
    SpeechCapabilityState capabilities,
    RecognitionPurpose purpose,
  ) {
    final modelId = config?.onlineModelFor(purpose) ?? '';
    final capability = config == null
        ? null
        : capabilities.capabilityFor(
            config: config,
            credentialVersion: state.credentialVersion,
            purpose: purpose,
          );
    final canTest =
        config != null &&
        state.hasApiKey &&
        modelId.isNotEmpty &&
        !widget.saving &&
        capabilities.testingPurpose != purpose;
    return ListTile(
      enabled: config != null && !widget.saving,
      title: Text(
        l10n.speechProviderOnlineModel(recognitionPurposeLabel(l10n, purpose)),
      ),
      subtitle: Text(
        modelId.isEmpty
            ? '—'
            : '$modelId\n${_capabilityLabel(l10n, capability)}',
      ),
      isThreeLine: modelId.isNotEmpty,
      trailing: _testButton(l10n, capabilities, purpose, canTest),
      onTap: config == null || widget.saving
          ? null
          : () => _openModelPicker(config, purpose),
    );
  }

  Widget _testButton(
    AppLocalizations l10n,
    SpeechCapabilityState capabilities,
    RecognitionPurpose purpose,
    bool canTest,
  ) {
    if (capabilities.testingPurpose == purpose) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    // 文字按钮比行尾图标更容易读，也保持不低于 44dp 的触控区域。
    return TextButton(
      onPressed: canTest ? () => _test(purpose) : null,
      child: Text(l10n.speechCapabilityTest),
    );
  }

  /// 字幕可用是比「有文本」更强的结论；词时间戳单独标注，未请求时不算支持。
  String _capabilityLabel(AppLocalizations l10n, SpeechCapability? capability) {
    if (capability == null) return l10n.speechCapabilityUnverified;
    return [
      capability.segments
          ? l10n.speechCapabilitySubtitles
          : l10n.speechCapabilityTextOnly,
      if (capability.wordTimestamps) l10n.speechCapabilityWords,
    ].join(' · ');
  }

  /// 首次向该服务上传样本前告知接收方、下游供应商与可能收费。
  Future<bool> _confirmUpload(
    AppLocalizations l10n,
    SpeechConfig config,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.speechUploadNoticeTitle),
        content: Text(
          l10n.speechUploadNoticeBody(
            Uri.parse(config.baseUrl).host,
            config.kind == SpeechProviderKind.openrouter
                ? l10n.speechUploadProviderOpenRouter
                : l10n.speechUploadProviderCustom,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.speechUploadNoticeConfirm),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// 一次付费验证：先告知，再发一次请求；失败只提示原因，不自动重试。
  Future<void> _test(RecognitionPurpose purpose) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(speechCapabilityProvider.notifier);
    final config = ref.read(speechConfigurationProvider).valueOrNull?.config;
    if (config == null) return;
    if (await notifier.needsUploadNotice()) {
      if (!mounted) return;
      if (!await _confirmUpload(l10n, config) || !mounted) return;
    }
    setState(() => _error = null);
    try {
      await notifier.test(purpose);
      if (!mounted) return;
      final verified = ref
          .read(speechCapabilityProvider)
          .valueOrNull
          ?.capabilityFor(
            config: config,
            credentialVersion: ref
                .read(speechConfigurationProvider)
                .valueOrNull
                ?.credentialVersion,
            purpose: purpose,
          );
      if (verified == null) return;
      final cost = verified.reportedCost;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            cost == null
                ? l10n.speechCapabilityVerifiedCostUnknown
                : l10n.speechCapabilityVerifiedCost(cost.toString()),
          ),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = speechErrorText(context, error));
    }
  }

  /// 点击「获取转写模型」时拉取一次 OpenRouter 目录。
  ///
  /// 这是只读查询：不上传音频、不写能力记录、不产生验证费用。列表只保留在本页
  /// 会话，[generation] 与当前代次不一致（配置变化、重新获取或页面已卸载）时丢弃结果。
  Future<void> _fetchModels() async {
    final l10n = AppLocalizations.of(context)!;
    final generation = ++_catalogGeneration;
    setState(() {
      _fetchingModels = true;
      _modelListMessage = null;
    });
    final List<String> models;
    try {
      models = await ref
          .read(speechCapabilityProvider.notifier)
          .refreshModels();
    } catch (_) {
      if (!mounted || generation != _catalogGeneration) return;
      setState(() {
        _fetchingModels = false;
        _modelIds = null;
        _modelListMessage = l10n.speechModelRefreshFailed;
      });
      return;
    }
    if (!mounted || generation != _catalogGeneration) return;
    setState(() {
      _fetchingModels = false;
      _modelIds = models.isEmpty ? null : models;
      _modelListMessage = models.isEmpty ? l10n.speechModelRefreshEmpty : null;
    });
  }

  /// 供应商、根地址或 Key 变化后清空目录：旧服务的模型不能选到新服务上。
  ///
  /// 已保存的在线模型不受影响，只是不能再从旧列表里选。
  void _clearCatalogOnServiceChange(
    AsyncValue<SpeechConfigurationState>? previous,
    AsyncValue<SpeechConfigurationState> next,
  ) {
    final before = previous?.valueOrNull;
    final after = next.valueOrNull;
    if (before == null || after == null) return;
    final serviceChanged =
        before.config?.kind != after.config?.kind ||
        before.config?.baseUrl != after.config?.baseUrl ||
        before.credentialVersion != after.credentialVersion;
    if (!serviceChanged) return;
    _catalogGeneration++;
    if (_modelIds == null && _modelListMessage == null && !_fetchingModels) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _modelIds = null;
      _modelListMessage = null;
      _fetchingModels = false;
    });
  }

  /// 模型行的唯一入口：已有目录时打开可滚动选择器，否则直接手填。
  ///
  /// 选择器底部保留手填入口；选中只改当前用途，仍走 [onSave] 的在途任务确认。
  Future<void> _openModelPicker(
    SpeechConfig config,
    RecognitionPurpose purpose,
  ) async {
    final models = _modelIds;
    if (models == null || models.isEmpty) {
      await _editModel(config, purpose);
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final current = config.onlineModelFor(purpose);
    final choice = await showModalBottomSheet<({String? modelId})>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.m,
                AppSpacing.m,
                AppSpacing.m,
                AppSpacing.s,
              ),
              child: Text(
                l10n.speechProviderOnlineModel(
                  recognitionPurposeLabel(l10n, purpose),
                ),
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final modelId in models)
                    ListTile(
                      title: Text(
                        modelId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      selected: modelId == current,
                      trailing: modelId == current
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () =>
                          Navigator.pop(sheetContext, (modelId: modelId)),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l10n.speechModelManualEntry),
              onTap: () => Navigator.pop(sheetContext, (modelId: null)),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final modelId = choice.modelId;
    if (modelId == null) {
      await _editModel(config, purpose);
      return;
    }
    await widget.onSave(config.withOnlineModel(purpose, modelId));
  }

  Future<void> _editModel(
    SpeechConfig config,
    RecognitionPurpose purpose,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final value = await _input(
      l10n.speechProviderOnlineModel(recognitionPurposeLabel(l10n, purpose)),
      config.onlineModelFor(purpose),
      (_) => null,
    );
    if (value == null || !mounted) return;
    await widget.onSave(config.withOnlineModel(purpose, value));
  }

  Future<String?> _input(
    String title,
    String initial,
    String? Function(String) validate,
  ) => showDialog<String>(
    context: context,
    builder: (_) => ProviderInputDialog(
      title: title,
      initial: initial,
      validate: validate,
    ),
  );
}
