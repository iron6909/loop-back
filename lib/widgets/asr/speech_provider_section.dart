/// 在线语音服务配置区：一份服务类型、根地址与 Key，三个用途各自的在线模型。
///
/// 这是「在线语音服务」页的正文卡片，不含页标题与整体状态行；语音识别页只保留
/// 一行入口（[speechProviderStatusText] 同时供入口行与页首状态使用）。
/// 保存与刷新只写本机配置或只读模型目录；测试按用户主动触发并先完成上传告知，
/// 使用随包英语样本，不发用户录音。模型目录成功不等于能力验证，逐用途显示
/// 文本可用 / 字幕可用 / 可选词时间戳。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/provider_settings/widgets/provider_input_dialog.dart';
import '../../l10n/app_localizations.dart';
import '../../models/recognition_selection.dart';
import '../../providers/recognition_settings_provider.dart';
import '../../providers/speech_capability_provider.dart';
import '../../providers/speech_configuration_provider.dart';
import '../../services/provider/provider_config.dart' show baseUrlError;
import '../../services/speech/speech_capability.dart';
import '../../services/speech/speech_config.dart';
import '../../services/speech/speech_error_text.dart';
import '../../theme/app_theme.dart';
import 'recognition_purpose_section.dart'
    show confirmCancelInFlightTasks, recognitionPurposeLabel;

/// 在线语音服务的整体状态文案。
///
/// 语音识别页的入口行与在线语音服务页共用这一份推导，避免两处各写一套文案。
String speechProviderStatusText(
  AppLocalizations l10n,
  SpeechConfigurationState state,
  SpeechCapabilityState capabilities,
) {
  final config = state.config;
  if (config == null) return l10n.speechProviderStatusUnconfigured;
  if (!state.hasApiKey) return l10n.speechProviderStatusMissingKey;
  final verified = RecognitionPurpose.values.any(
    (purpose) =>
        capabilities.capabilityFor(
          config: config,
          credentialVersion: state.credentialVersion,
          purpose: purpose,
        ) !=
        null,
  );
  return verified
      ? l10n.speechProviderStatusVerified
      : l10n.speechProviderStatusUnverified;
}

/// 服务类型文案：OpenRouter 预设或自定义服务。
String speechProviderKindText(AppLocalizations l10n, SpeechProviderKind kind) =>
    switch (kind) {
      SpeechProviderKind.openrouter => l10n.providerKindOpenRouter,
      SpeechProviderKind.custom => l10n.providerKindCustom,
    };

/// 在线语音服务配置卡片（不含页标题与状态行）。
class SpeechProviderSection extends ConsumerStatefulWidget {
  const SpeechProviderSection({super.key});

  @override
  ConsumerState<SpeechProviderSection> createState() =>
      _SpeechProviderSectionState();
}

class _SpeechProviderSectionState extends ConsumerState<SpeechProviderSection> {
  bool _saving = false;
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
    return Card(
      child: Column(
        children: [
          _row(
            l10n.aiServiceProvider,
            config == null ? null : speechProviderKindText(l10n, config.kind),
            () => _pickKind(config),
          ),
          _row(
            l10n.aiServiceBaseUrl,
            config?.baseUrl,
            config == null ? null : () => _editBaseUrl(config),
          ),
          _row(
            l10n.aiServiceApiKey,
            state.hasApiKey ? l10n.aiServiceKeySaved : l10n.aiServiceKeyNotSet,
            config == null ? null : () => _editKey(config),
          ),
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
      ),
    );
  }

  Widget _row(String label, String? value, VoidCallback? action) => ListTile(
    enabled: action != null && !_saving,
    title: Text(label),
    subtitle: value == null
        ? null
        : Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: const Icon(Icons.chevron_right),
    onTap: _saving ? null : action,
  );

  /// 一个用途的在线模型行：手填始终可用，OpenRouter 额外提供目录刷新，
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
    final testing = capabilities.testingPurpose == purpose;
    final canTest =
        config != null &&
        state.hasApiKey &&
        modelId.isNotEmpty &&
        !_saving &&
        !testing;
    return ListTile(
      enabled: config != null && !_saving,
      title: Text(
        l10n.speechProviderOnlineModel(recognitionPurposeLabel(l10n, purpose)),
      ),
      subtitle: Text(
        modelId.isEmpty
            ? '—'
            : '$modelId\n${_capabilityLabel(l10n, capability)}',
      ),
      isThreeLine: modelId.isNotEmpty,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (config?.kind == SpeechProviderKind.openrouter)
            IconButton(
              tooltip: l10n.speechModelRefresh,
              icon: const Icon(Icons.refresh),
              onPressed: _saving || testing
                  ? null
                  : () => _refreshModels(purpose),
            ),
          if (testing)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            // 文字按钮比行尾图标更容易读，也保持不低于 44dp 的触控区域。
            TextButton(
              onPressed: canTest ? () => _test(purpose) : null,
              child: Text(l10n.speechCapabilityTest),
            ),
        ],
      ),
      onTap: config == null || _saving
          ? null
          : () => _editModel(config, purpose),
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

  /// 刷新 OpenRouter 专用转写目录；列表为空或失败都只提示，手填不受影响。
  Future<void> _refreshModels(RecognitionPurpose purpose) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _error = null);
    final List<String> models;
    try {
      models = await ref
          .read(speechCapabilityProvider.notifier)
          .refreshModels();
    } catch (_) {
      if (mounted) setState(() => _error = l10n.speechModelRefreshFailed);
      return;
    }
    if (!mounted) return;
    if (models.isEmpty) {
      setState(() => _error = l10n.speechModelRefreshEmpty);
      return;
    }
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(l10n.speechModelRefresh),
        children: [
          for (final modelId in models)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, modelId),
              child: Text(modelId),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    final config = ref.read(speechConfigurationProvider).valueOrNull?.config;
    if (config == null) return;
    await _save(config.withOnlineModel(purpose, selected));
  }

  Future<void> _pickKind(SpeechConfig? current) async {
    final l10n = AppLocalizations.of(context)!;
    final kind = await showDialog<SpeechProviderKind>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(l10n.aiServiceProvider),
        children: [
          for (final option in SpeechProviderKind.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, option),
              child: Text(speechProviderKindText(l10n, option)),
            ),
        ],
      ),
    );
    if (kind == null || !mounted) return;
    var baseUrl = kind.presetBaseUrl;
    if (baseUrl == null) {
      baseUrl = await _input(
        l10n.aiServiceBaseUrl,
        current?.baseUrl ?? '',
        _baseUrlValidation(l10n),
      );
      if (baseUrl == null || !mounted) return;
    }
    await _save(
      SpeechConfig(
        kind: kind,
        baseUrl: baseUrl,
        onlineModels: current?.onlineModels ?? const {},
      ),
    );
  }

  Future<void> _editBaseUrl(SpeechConfig config) async {
    final l10n = AppLocalizations.of(context)!;
    final value = await _input(
      l10n.aiServiceBaseUrl,
      config.baseUrl,
      _baseUrlValidation(l10n),
    );
    if (value == null || !mounted) return;
    await _save(
      SpeechConfig(
        kind: config.kind,
        baseUrl: value,
        onlineModels: config.onlineModels,
      ),
    );
  }

  /// Key 不回显：输入空值等于删除，取消对话框则保持原凭据。
  Future<void> _editKey(SpeechConfig config) async {
    final l10n = AppLocalizations.of(context)!;
    final value = await _input(
      l10n.aiServiceApiKey,
      '',
      (_) => null,
      secret: true,
    );
    if (value == null || !mounted) return;
    await _save(config, apiKey: value);
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
    await _save(config.withOnlineModel(purpose, value));
  }

  String? Function(String) _baseUrlValidation(AppLocalizations l10n) =>
      (text) =>
          baseUrlError(text) == null ? null : l10n.aiServiceBaseUrlInvalid;

  Future<String?> _input(
    String title,
    String initial,
    String? Function(String) validate, {
    bool secret = false,
  }) => showDialog<String>(
    context: context,
    builder: (_) => ProviderInputDialog(
      title: title,
      initial: initial,
      validate: validate,
      secret: secret,
    ),
  );

  /// 保存配置。
  ///
  /// 服务类型、地址、Key 或某个用途的在线模型变化后，旧配置的在途在线任务结果
  /// 不再可用：先告知用户，拒绝则不改配置也不动任务，接受才取消这些任务。
  /// 本机/系统方式的任务与其它用途的无关任务不受影响。
  Future<void> _save(SpeechConfig config, {String? apiKey}) async {
    final registry = ref.read(recognitionInFlightTasksProvider);
    final affected = registry.pendingOnline(
      _affectedPurposes(config, credentialChanged: apiKey != null),
    );
    if (affected.isNotEmpty) {
      if (!mounted) return;
      if (!await confirmCancelInFlightTasks(context, affected)) return;
      await registry.cancel(affected);
      if (!mounted) return;
    }
    final failureText = AppLocalizations.of(context)!.speechProviderSaveFailed;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(speechConfigurationProvider.notifier)
          .save(config, apiKey: apiKey);
    } catch (_) {
      if (mounted) setState(() => _error = failureText);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 本次保存会影响的用途范围。
  ///
  /// 服务类型与根地址全用途共用，[credentialChanged] 时 Key 也变：这两种情况影响
  /// 全部用途；否则只有在线模型真的变了的用途受影响。
  Set<RecognitionPurpose> _affectedPurposes(
    SpeechConfig next, {
    required bool credentialChanged,
  }) {
    final current = ref.read(speechConfigurationProvider).valueOrNull?.config;
    if (current == null ||
        credentialChanged ||
        current.kind != next.kind ||
        current.baseUrl != next.baseUrl) {
      return RecognitionPurpose.values.toSet();
    }
    return {
      for (final purpose in RecognitionPurpose.values)
        if (current.onlineModelFor(purpose) != next.onlineModelFor(purpose))
          purpose,
    };
  }
}
