/// 在线语音服务配置区：一份服务类型、根地址与 Key，三个用途各自的在线模型。
///
/// 这是「在线语音服务」页的正文卡片，不含页标题与整体状态行；语音识别页只保留
/// 一行入口（[speechProviderStatusText] 同时供入口行与页首状态使用）。
/// 保存只写本机配置；按用途在线模型的目录、选择与验证在
/// [SpeechOnlineModelSection]，这里只负责连接配置与保存。
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
import '../../services/speech/speech_config.dart';
import '../../theme/app_theme.dart';
import 'recognition_purpose_section.dart' show confirmCancelInFlightTasks;
import 'speech_online_model_section.dart';

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

/// 在线语音整体状态的颜色：未配置或缺少 Key 用错误色，其余用次要文字色。
///
/// 入口行与在线服务页共用，避免同一状态在两处各写一套判断。
Color speechProviderStatusColor(
  ThemeData theme,
  SpeechConfigurationState state,
) => state.isConfigured
    ? theme.colorScheme.onSurfaceVariant
    : theme.colorScheme.error;

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
          const Divider(height: 1, indent: 16, endIndent: 16),
          SpeechOnlineModelSection(saving: _saving, onSave: _save),
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
  /// 本机/系统方式的任务与其它用途的无关任务不受影响。目录作废由
  /// [SpeechOnlineModelSection] 监听配置身份变化完成，这里不重复处理。
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
