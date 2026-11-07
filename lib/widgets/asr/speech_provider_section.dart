/// 在线语音服务配置区：一份服务类型、根地址与 Key，三个用途各自的在线模型。
///
/// 保存只写本机普通配置与安全存储里的 Key，不发出任何请求；本切片只区分未配置
/// 与已保存未验证，能力验证由后续切片接入后才影响在线可用性。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/provider_settings/widgets/provider_input_dialog.dart';
import '../../l10n/app_localizations.dart';
import '../../models/recognition_selection.dart';
import '../../providers/speech_configuration_provider.dart';
import '../../services/provider/provider_config.dart' show baseUrlError;
import '../../services/speech/speech_config.dart';
import '../../theme/app_theme.dart';
import 'recognition_purpose_section.dart' show recognitionPurposeLabel;

/// 在线语音服务配置卡片。
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
          ListTile(
            leading: Icon(
              Icons.cloud_outlined,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            title: Text(l10n.speechProviderTitle),
            subtitle: Text(
              _statusText(l10n, state),
              style: theme.textTheme.bodySmall?.copyWith(
                color: state.isConfigured
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.error,
              ),
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _row(
            l10n.aiServiceProvider,
            config == null ? null : _kindLabel(l10n, config.kind),
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
            _row(
              l10n.speechProviderOnlineModel(
                recognitionPurposeLabel(l10n, purpose),
              ),
              config == null ? null : _modelLabel(config, purpose),
              config == null ? null : () => _editModel(config, purpose),
            ),
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

  String _statusText(AppLocalizations l10n, SpeechConfigurationState state) {
    if (state.config == null) return l10n.speechProviderStatusUnconfigured;
    if (!state.hasApiKey) return l10n.speechProviderStatusMissingKey;
    return l10n.speechProviderStatusUnverified;
  }

  String _kindLabel(AppLocalizations l10n, SpeechProviderKind kind) =>
      switch (kind) {
        SpeechProviderKind.openrouter => l10n.providerKindOpenRouter,
        SpeechProviderKind.custom => l10n.providerKindCustom,
      };

  String _modelLabel(SpeechConfig config, RecognitionPurpose purpose) {
    final modelId = config.onlineModelFor(purpose);
    return modelId.isEmpty ? '—' : modelId;
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
              child: Text(_kindLabel(l10n, option)),
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

  /// 保存失败时保留原配置，只在卡片内提示原因。
  Future<void> _save(SpeechConfig config, {String? apiKey}) async {
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
}
