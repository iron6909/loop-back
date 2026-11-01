/// AI 服务页：非敏感配置可独立编辑，Key 不回显；验证结果内联显示。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../../providers/provider_configuration_provider.dart';
import '../../../services/provider/provider_config.dart';
import '../../../services/provider/provider_error_text.dart';
import '../../../services/provider/usage_query_service.dart';
import '../../../theme/app_theme.dart';
import '../providers/usage_provider.dart';
import '../widgets/provider_input_dialog.dart';
import '../widgets/usage_card.dart';

class AiServiceScreen extends ConsumerStatefulWidget {
  const AiServiceScreen({super.key});
  @override
  ConsumerState<AiServiceScreen> createState() => _AiServiceScreenState();
}

class _AiServiceScreenState extends ConsumerState<AiServiceScreen> {
  bool _saving = false;
  bool _testing = false;
  String? _result;
  CancelToken? _testToken;
  int _generation = 0;

  @override
  void dispose() {
    _testToken?.cancel('page closed');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final runtime = ref.watch(providerConfigurationProvider).valueOrNull;
    final saved = ref.watch(savedProviderConfigProvider);
    final config = saved.valueOrNull ?? runtime?.config;
    final usage = ref.watch(usageQueryProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.aiServiceTitle)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.m),
        children: [
          if (runtime == null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.m),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.aiServiceNotConfigured),
                    FilledButton(
                      onPressed: _saving ? null : () => _pick(config),
                      child: Text(l10n.aiServiceConfigureProvider),
                    ),
                  ],
                ),
              ),
            )
          else
            UsageCard(
              view: usage.isReloading ? const UsageView()
                  : usage.valueOrNull ?? const UsageView(),
              providerName: _kind(l10n, runtime.config.kind),
              isRefreshing: usage.isLoading,
              onRefresh: () => ref.read(usageQueryProvider.notifier).refresh(),
              onOpenConsole: () =>
                  launchUrl(Uri.parse(_console(runtime.config))),
            ),
          const SizedBox(height: AppSpacing.m),
          _fields(l10n, config, runtime != null),
          if (_result case final result?)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s),
              child: Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    const Icon(Icons.info_outline),
                    const SizedBox(width: AppSpacing.s),
                    Expanded(child: Text(result)),
                  ],
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.m),
          Card(
            child: ListTile(
              title: Text(l10n.aiServicePromptVersion),
              subtitle: Text(l10n.aiServiceAbout),
              trailing: Text(config?.promptVersion ?? 'v1'),
            ),
          ),
        ],
      ),
    );
  }

  /// 各字段独立编辑，首次选择供应商后不依赖 Key 才能继续操作。
  Widget _fields(AppLocalizations l10n, ProviderConfig? config, bool hasKey) {
    return Card(
      child: Column(
        children: [
          _row(
            l10n.aiServiceProvider,
            _kind(l10n, config?.kind),
            () => _pick(config),
          ),
          _row(
            l10n.aiServiceBaseUrl,
            config?.baseUrl,
            config == null ? null : () => _edit(config, url: true),
          ),
          _row(
            l10n.aiServiceModel,
            config?.model,
            config == null ? null : () => _edit(config, url: false),
          ),
          _row(
            l10n.aiServiceApiKey,
            hasKey ? l10n.aiServiceKeySaved : l10n.aiServiceKeyNotSet,
            config == null ? null : () => _key(config),
          ),
          ListTile(
            title: Text(l10n.aiServiceConnectionTest),
            subtitle: Text(
              !hasKey ? l10n.aiServiceKeyNotSet : l10n.aiServiceUntested,
            ),
            trailing: FilledButton.tonal(
              onPressed: !hasKey || _testing || _saving ? null : _test,
              child: Text(
                _testing ? l10n.aiServiceTesting : l10n.aiServiceTest,
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

  String _kind(AppLocalizations l10n, ProviderKind? kind) => switch (kind) {
    ProviderKind.deepseek => l10n.providerKindDeepSeek,
    ProviderKind.openrouter => l10n.providerKindOpenRouter,
    ProviderKind.custom => l10n.providerKindCustom,
    null => '—',
  };

  String _console(ProviderConfig config) =>
      switch (Uri.parse(config.baseUrl).host) {
        'api.deepseek.com' => 'https://platform.deepseek.com',
        'openrouter.ai' => 'https://openrouter.ai/settings/keys',
        _ => 'https://opencode.ai',
      };

  Future<void> _pick(ProviderConfig? current) async {
    final l10n = AppLocalizations.of(context)!;
    final kind = await showDialog<ProviderKind>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.aiServiceProvider),
        children: [
          for (final kind in ProviderKind.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, kind),
              child: Text(_kind(l10n, kind)),
            ),
        ],
      ),
    );
    if (kind == null || !mounted) return;
    var url = kind.presetBaseUrl;
    var model = kind.presetModel;
    if (kind == ProviderKind.custom) {
      url = await _input(
        l10n.aiServiceBaseUrl,
        '',
        (text) =>
            baseUrlError(text) == null ? null : l10n.aiServiceBaseUrlInvalid,
      );
      if (url == null || !mounted) return;
      model = await _input(
        l10n.aiServiceModel,
        '',
        (text) => text.isEmpty ? l10n.aiServiceModel : null,
      );
    }
    if (url == null || model == null || !mounted) return;
    await _save(
      ProviderConfig(
        kind: kind,
        baseUrl: url,
        model: model,
        promptVersion: current?.promptVersion ?? 'v1',
      ),
    );
  }

  Future<void> _edit(ProviderConfig config, {required bool url}) async {
    final l10n = AppLocalizations.of(context)!;
    final value = await _input(
      url ? l10n.aiServiceBaseUrl : l10n.aiServiceModel,
      url ? config.baseUrl : config.model,
      (text) => url
          ? (baseUrlError(text) == null ? null : l10n.aiServiceBaseUrlInvalid)
          : text.isEmpty
          ? l10n.aiServiceModel
          : null,
    );
    if (value == null || !mounted) return;
    await _save(
      ProviderConfig(
        kind: config.kind,
        baseUrl: url ? value : config.baseUrl,
        model: url ? config.model : value,
        promptVersion: config.promptVersion,
      ),
    );
  }

  Future<void> _key(ProviderConfig config) async {
    final l10n = AppLocalizations.of(context)!;
    final value = await _input(
      l10n.aiServiceApiKey,
      '',
      (text) => RegExp(r'[\r\n]').hasMatch(text)
          ? l10n.aiServiceTestUnauthorized
          : null,
      secret: true,
      hint: l10n.aiServiceKeyHint,
    );
    if (value != null && mounted) await _save(config, apiKey: value);
  }

  Future<String?> _input(
    String title,
    String initial,
    String? Function(String) validate, {
    bool secret = false,
    String? hint,
  }) => showDialog<String>(
    context: context,
    builder: (_) => ProviderInputDialog(
      title: title,
      initial: initial,
      validate: validate,
      secret: secret,
      hint: hint,
    ),
  );

  Future<void> _save(ProviderConfig config, {String? apiKey}) async {
    _generation++;
    _testToken?.cancel('config changed');
    setState(() {
      _saving = true;
      _testing = false;
      _result = null;
    });
    try {
      await ref
          .read(providerConfigurationProvider.notifier)
          .save(config, apiKey: apiKey);
    } catch (error) {
      if (mounted) setState(() => _result = providerErrorText(context, error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 用户触发的最小推理，不由状态刷新自动触发。
  Future<void> _test() async {
    final runtime = ref.read(providerConfigurationProvider).valueOrNull;
    if (runtime == null) return;
    final generation = ++_generation;
    final token = CancelToken();
    _testToken = token;
    setState(() {
      _testing = true;
      _result = null;
    });
    String result;
    try {
      final response = await runtime.http.postChatCompletions({
        'model': runtime.config.model,
        'messages': [
          {'role': 'user', 'content': 'Say OK'},
        ],
        'max_tokens': 32,
        if (runtime.config.kind == ProviderKind.deepseek)
          'thinking': {'type': 'disabled'},
      }, cancelToken: token);
      if (!mounted) return;
      result = switch (response['choices']) {
        [
          {'finish_reason': 'stop', 'message': {'content': final String text}},
          ...,
        ]
            when text.trim().isNotEmpty =>
          AppLocalizations.of(context)!.aiServiceTestSuccess,
        _ => providerErrorCodeText(
          'invalidResponse',
          Localizations.localeOf(context).languageCode == 'zh',
        ),
      };
    } catch (error) {
      if (!mounted || token.isCancelled) return;
      result = providerErrorText(context, error);
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _testing = false;
      _result = result;
    });
  }
}
