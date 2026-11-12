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
    final provider = ref.watch(providerConfigurationProvider);
    final runtime = provider.valueOrNull;
    final saved = ref.watch(savedProviderConfigProvider);
    final config = saved.valueOrNull ?? runtime?.config;
    final usage = ref.watch(usageQueryProvider);
    // 首帧仍在读配置：先给读中占位，避免把已配置用户瞬时误判为未配置。
    if (config == null &&
        runtime == null &&
        (provider.isLoading || saved.isLoading)) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.aiServiceTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    // 从未保存过配置：整页空态，不渲染暂时无意义的配置行。
    if (config == null && runtime == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.aiServiceTitle)),
        body: _empty(l10n),
      );
    }
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.aiServiceTitle)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.m),
        children: [
          Text(
            l10n.aiServiceIntro,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.m),
          if (config != null) _providerCard(l10n, config),
          if (runtime != null) ...[
            if (config != null) const SizedBox(height: AppSpacing.m),
            UsageCard(
              view: usage.isReloading
                  ? const UsageView()
                  : usage.valueOrNull ?? const UsageView(),
              providerName: _kind(l10n, runtime.config.kind),
              isRefreshing: usage.isLoading,
              onRefresh: () => ref.read(usageQueryProvider.notifier).refresh(),
              onOpenConsole: () =>
                  launchUrl(Uri.parse(_console(runtime.config))),
            ),
          ],
          _sectionTitle(context, l10n.aiServiceConnectionSection),
          _fields(l10n, config, runtime != null),
          const SizedBox(height: AppSpacing.m),
          _testCard(l10n, runtime != null),
          const SizedBox(height: AppSpacing.l),
          Center(
            child: Text(
              '${l10n.aiServicePromptVersion} ${config?.promptVersion ?? 'v1'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.m),
        ],
      ),
    );
  }

  /// 从未配置时的整页空态：说明用途与支持范围，只留一个主操作。
  Widget _empty(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(AppSpacing.l),
              ),
              child: Icon(
                Icons.hub_outlined,
                size: 44,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: AppSpacing.l),
            Text(
              l10n.aiServiceNotConfigured,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpacing.s),
            Text(
              l10n.aiServiceEmptyDescription,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : () => _pick(null),
                child: Text(l10n.aiServiceConfigureProvider),
              ),
            ),
            const SizedBox(height: AppSpacing.m),
            Text(
              l10n.aiServiceEmptyHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 供应商身份卡：名称、模型与主机一眼可见，修改入口在右侧。
  Widget _providerCard(AppLocalizations l10n, ProviderConfig config) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('ai-service-provider-card'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.m),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(
                  AppSpacing.s + AppSpacing.xs,
                ),
              ),
              child: Icon(
                Icons.hub_outlined,
                size: 26,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: AppSpacing.s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _kind(l10n, config.kind),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs / 2),
                  Text(
                    '${config.model} · ${_host(config)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: l10n.aiServiceChangeProvider,
              onPressed: _saving ? null : () => _pick(config),
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
      ),
    );
  }

  /// 分区标题：与设置页分组同款样式。
  Widget _sectionTitle(BuildContext context, String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xs,
        AppSpacing.l,
        AppSpacing.xs,
        AppSpacing.s,
      ),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// 各字段独立编辑，首次选择供应商后不依赖 Key 才能继续操作。
  /// 供应商入口收在身份卡的编辑按钮上，避免同一信息出现两次。
  Widget _fields(AppLocalizations l10n, ProviderConfig? config, bool hasKey) {
    return Card(
      child: Column(
        children: [
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
        ],
      ),
    );
  }

  /// 连接验证卡：结果内联，动作在右；没有 Key 时按钮禁用并说明原因。
  Widget _testCard(AppLocalizations l10n, bool hasKey) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.m,
          AppSpacing.s + AppSpacing.xs,
          AppSpacing.s,
          AppSpacing.s + AppSpacing.xs,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.aiServiceConnectionTest,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Semantics(
                    liveRegion: true,
                    child: Row(
                      children: [
                        if (_result != null) ...[
                          Icon(
                            Icons.info_outline,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: AppSpacing.xs),
                        ],
                        Flexible(
                          child: Text(
                            _statusText(l10n, hasKey),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s),
            FilledButton.tonal(
              onPressed: !hasKey || _testing || _saving ? null : _test,
              child: Text(
                _testing ? l10n.aiServiceTesting : l10n.aiServiceTest,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 验证行的状态文字：测试中优先，其次本次结果，最后回退到 Key 与验证状态。
  String _statusText(AppLocalizations l10n, bool hasKey) => _testing
      ? l10n.aiServiceTesting
      : _result ?? (hasKey ? l10n.aiServiceUntested : l10n.aiServiceKeyNotSet);

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

  String _console(ProviderConfig config) => switch (_host(config)) {
    'api.deepseek.com' => 'https://platform.deepseek.com',
    'openrouter.ai' => 'https://openrouter.ai/settings/keys',
    _ => 'https://opencode.ai',
  };

  /// 主机名：身份卡与用量快照都只需要这一层。
  String _host(ProviderConfig config) => Uri.parse(config.baseUrl).host;

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
