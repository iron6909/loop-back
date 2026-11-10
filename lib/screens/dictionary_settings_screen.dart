/// 词典设置页面
///
/// 设置默认词典源（单选，列已启用源），并启用/禁用可选源
/// （本地/AI 不可禁用，置灰锁定；其它可开关）。被禁用的源不出现在查词切换器。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../providers/dictionary/dictionary_offline_resources_provider.dart';
import '../providers/dictionary/dictionary_registry.dart';
import '../providers/dictionary/dictionary_settings_provider.dart';
import '../providers/dictionary/visible_sources_provider.dart';
import '../providers/dictionary_provider.dart';
import '../providers/offline_asr_settings_provider.dart';
import '../providers/pronunciation/pronunciation_providers.dart';
import '../providers/settings_provider.dart';
import '../services/asr/asr_model_catalog.dart';
import '../services/dictionary/dictionary_catalog.dart';
import '../services/dictionary/dictionary_source.dart';
import '../services/download/download_failure.dart';
import '../services/resource_archive_spec.dart';
import '../theme/app_theme.dart';
import '../utils/download_failure_message.dart';
import '../utils/file_size.dart';
import '../widgets/asr/asr_download_source_presentation.dart';
import '../widgets/dictionary/dict_source_presentation.dart';

/// 词典设置页面
class DictionarySettingsScreen extends ConsumerWidget {
  const DictionarySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final allSources = ref.watch(dictionarySourcesProvider);
    final visible = ref.watch(visibleDictionarySourcesProvider);
    final settings = ref.watch(dictionarySettingsNotifierProvider);
    final notifier = ref.read(dictionarySettingsNotifierProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.dictionarySettings)),
      body: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.m,
          vertical: AppSpacing.s,
        ),
        children: [
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.volume_up_outlined),
                  title: Text(l10n.dictionaryAutoSpeakOnLookup),
                  value: settings.autoSpeakOnLookup,
                  onChanged: notifier.setAutoSpeakOnLookup,
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.block_outlined),
                  title: Text(l10n.dictionaryAdFilterTitle),
                  value: settings.adFilteringEnabled,
                  onChanged: notifier.setAdFilteringEnabled,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.m),
          _SectionHeader(
            title: l10n.dictionaryDefault,
            description: l10n.dictionaryDefaultDescription,
          ),
          Card(
            child: Column(
              children: [
                for (final s in visible)
                  ListTile(
                    leading: _SourceIcon(source: s),
                    title: Text(dictSourceLabel(l10n, s.id)),
                    trailing: settings.defaultSourceId == s.id
                        ? Icon(
                            Icons.check_circle,
                            color: theme.colorScheme.primary,
                          )
                        : Icon(
                            Icons.circle_outlined,
                            color: theme.colorScheme.outlineVariant,
                          ),
                    onTap: () => notifier.setDefault(s.id),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.m),
          _SectionHeader(
            title: l10n.dictionarySources,
            description: l10n.dictionarySourcesDescription,
          ),
          Card(
            child: Column(
              children: [
                for (final s in allSources)
                  _SourceToggleTile(
                    source: s,
                    enabled: !settings.disabledIds.contains(s.id),
                    onChanged: (v) => notifier.setDisabled(s.id, !v),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.m),
          _SectionHeader(
            title: l10n.offlineResourcesTitle,
            description: l10n.offlineResourcesDescription,
          ),
          Card(
            child: Column(
              children: [
                for (final lang in dictionarySpecs.keys)
                  _DictionaryResourceTile(nativeLanguage: lang),
                const Divider(height: 1),
                const _PronunciationResourceTile(),
                const Divider(height: 1),
                const _DownloadSourceTile(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 词典源图标：用品牌色给图标本身着色，让各源在列表中可区分。
class _SourceIcon extends StatelessWidget {
  final DictionarySource source;
  const _SourceIcon({required this.source});

  @override
  Widget build(BuildContext context) {
    final color = dictSourceColor(Theme.of(context).colorScheme, source.id);
    return Icon(source.icon, color: color);
  }
}

/// 分组标题 + 说明
class _SectionHeader extends StatelessWidget {
  final String title;
  final String description;
  const _SectionHeader({required this.title, required this.description});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s,
        AppSpacing.s,
        AppSpacing.s,
        AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个源的启用/禁用项：可禁用 → Switch；不可禁用 → 锁定灰字
class _SourceToggleTile extends StatelessWidget {
  final DictionarySource source;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _SourceToggleTile({
    required this.source,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final label = dictSourceLabel(l10n, source.id);
    final icon = _SourceIcon(source: source);

    if (!source.canBeDisabled) {
      return ListTile(
        leading: icon,
        title: Text(label),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              l10n.dictSourceAlwaysOn,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.dictSourceCannotDisable(label))),
        ),
      );
    }

    return SwitchListTile(
      secondary: icon,
      title: Text(label),
      value: enabled,
      onChanged: onChanged,
    );
  }
}

/// 下载进度块：进度条 + 百分比文案，词典与发音库共用。
class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({required this.l10n, required this.progress});

  final AppLocalizations l10n;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final percent = '${(progress * 100).toStringAsFixed(0)}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        LinearProgressIndicator(value: progress),
        const SizedBox(height: 2),
        Text(l10n.speechModelDownloading(percent)),
      ],
    );
  }
}

/// 单个语言变体的离线词典行：来源/许可 + 状态/进度/重试。
class _DictionaryResourceTile extends ConsumerWidget {
  const _DictionaryResourceTile({required this.nativeLanguage});

  final String nativeLanguage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final spec = dictionarySpecOf(nativeLanguage);
    final label = supportedNativeLanguages[nativeLanguage] ?? nativeLanguage;
    final dictState = ref.watch(dictionaryProvider);
    final isCurrent = dictState.nativeLanguage == nativeLanguage;

    if (isCurrent) {
      return ListTile(
        leading: const Icon(Icons.menu_book_outlined),
        title: Text(label),
        subtitle: _dictionarySubtitle(
          l10n,
          theme,
          spec,
          dictState.status,
          dictState.progress,
          dictState.failure,
        ),
        trailing: _dictionaryTrailing(l10n, dictState.status, ref),
      );
    }

    // 非当前母语不由 dictionaryProvider 管理，改用逐语言 provider 做安装检查与下载。
    final resource = ref.watch(dictionaryResourceProvider(nativeLanguage));
    final status = resource.status;
    final Widget? trailing;
    if (status == null) {
      trailing = null;
    } else {
      trailing = _dictionaryResourceTrailing(l10n, status, ref, nativeLanguage);
    }

    return ListTile(
      leading: const Icon(Icons.menu_book_outlined),
      title: Text(label),
      subtitle: _dictionarySubtitle(
        l10n,
        theme,
        spec,
        status,
        resource.progress,
        resource.failure,
      ),
      trailing: trailing,
    );
  }
}

/// 词典行的来源/许可与状态文案。[status] 为 null 表示仍在本地安装检查。
Widget _dictionarySubtitle(
  AppLocalizations l10n,
  ThemeData theme,
  DictionarySpec spec,
  DictionaryStatus? status,
  double progress,
  DownloadFailureKind? failure,
) {
  final statusLine = switch (status) {
    null => Text(
      l10n.downloadLoading,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
      ),
    ),
    DictionaryStatus.downloading => _DownloadProgress(
      l10n: l10n,
      progress: progress,
    ),
    DictionaryStatus.failed => Text(
      downloadFailureMessage(l10n, failure),
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.error,
      ),
    ),
    DictionaryStatus.notDownloaded => Text(
      l10n.dictionaryNotDownloaded,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
      ),
    ),
    DictionaryStatus.downloaded => Text(
      l10n.speechModelStatusReady,
      style: theme.textTheme.bodySmall?.copyWith(
        color: AppTheme.successColor,
        fontWeight: FontWeight.w500,
      ),
    ),
  };

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        l10n.dictionaryResourceSource(spec.license, spec.resource.repository),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        ),
      ),
      statusLine,
    ],
  );
}

/// 当前母语词典在未下载/失败时的下载与重试入口。
Widget? _dictionaryTrailing(
  AppLocalizations l10n,
  DictionaryStatus status,
  WidgetRef ref,
) {
  return switch (status) {
    DictionaryStatus.notDownloaded => TextButton(
      onPressed: () => ref.read(dictionaryProvider.notifier).retryDownload(),
      child: Text(l10n.download),
    ),
    DictionaryStatus.failed => TextButton(
      onPressed: () => ref.read(dictionaryProvider.notifier).retryDownload(),
      child: Text(l10n.retry),
    ),
    DictionaryStatus.downloading || DictionaryStatus.downloaded => null,
  };
}

/// 非当前母语词典在未下载/失败时的下载与重试入口。
Widget? _dictionaryResourceTrailing(
  AppLocalizations l10n,
  DictionaryStatus status,
  WidgetRef ref,
  String nativeLanguage,
) {
  return switch (status) {
    DictionaryStatus.notDownloaded => TextButton(
      onPressed: () => ref
          .read(dictionaryResourceProvider(nativeLanguage).notifier)
          .download(),
      child: Text(l10n.download),
    ),
    DictionaryStatus.failed => TextButton(
      onPressed: () => ref
          .read(dictionaryResourceProvider(nativeLanguage).notifier)
          .retryDownload(),
      child: Text(l10n.retry),
    ),
    DictionaryStatus.downloading || DictionaryStatus.downloaded => null,
  };
}

/// 离线发音库行：仅标注托管仓库（ADR-0002），状态与失败重试。
class _PronunciationResourceTile extends ConsumerWidget {
  const _PronunciationResourceTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final state = ref.watch(pronunciationLibraryProvider);

    final statusLine = switch (state.status) {
      PronunciationLibraryStatus.downloading => _DownloadProgress(
        l10n: l10n,
        progress: state.progress,
      ),
      PronunciationLibraryStatus.installing => Text(
        l10n.pronunciationInstalling,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        ),
      ),
      PronunciationLibraryStatus.ready => Text(
        l10n.speechModelReady(
          state.localSizeBytes > 0 ? formatBytes(state.localSizeBytes) : '—',
        ),
        style: theme.textTheme.bodySmall?.copyWith(
          color: AppTheme.successColor,
          fontWeight: FontWeight.w500,
        ),
      ),
      PronunciationLibraryStatus.failed => Text(
        downloadFailureMessage(l10n, state.failure),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
      PronunciationLibraryStatus.notDownloaded => Text(
        l10n.ttsModelNotDownloaded,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        ),
      ),
    };

    final trailing = switch (state.status) {
      PronunciationLibraryStatus.failed => TextButton(
        onPressed: () =>
            ref.read(pronunciationLibraryProvider.notifier).retryDownload(),
        child: Text(l10n.retry),
      ),
      PronunciationLibraryStatus.notDownloaded => TextButton(
        onPressed: () =>
            ref.read(pronunciationLibraryProvider.notifier).ensureDownloaded(),
        child: Text(l10n.download),
      ),
      PronunciationLibraryStatus.downloading ||
      PronunciationLibraryStatus.installing ||
      PronunciationLibraryStatus.ready => null,
    };

    return ListTile(
      leading: const Icon(Icons.record_voice_over_outlined),
      title: Text(l10n.pronunciationLibrary),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.pronunciationResourceSource(
              dictionaryPronunciationPublicRepository,
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
          statusLine,
        ],
      ),
      trailing: trailing,
    );
  }
}

/// 下载来源切换：与语音识别设置页共用同一份偏好，两处互见一致。
class _DownloadSourceTile extends ConsumerWidget {
  const _DownloadSourceTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final source = ref.watch(offlineAsrSettingsProvider).downloadSource;
    return ExpansionTile(
      leading: Icon(
        Icons.cloud_download_outlined,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(l10n.asrDownloadSourceTitle),
      subtitle: Text(asrDownloadSourceLabel(l10n, source)),
      shape: const Border(),
      collapsedShape: const Border(),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.m,
            0,
            AppSpacing.m,
            AppSpacing.s,
          ),
          child: Text(
            l10n.asrDownloadSourceDescription,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        RadioGroup<AsrDownloadSource>(
          groupValue: source,
          onChanged: (value) {
            if (value == null) return;
            ref
                .read(offlineAsrSettingsProvider.notifier)
                .setDownloadSource(value);
          },
          child: Column(
            children: [
              for (final s in AsrDownloadSource.values)
                RadioListTile<AsrDownloadSource>(
                  title: Text(asrDownloadSourceLabel(l10n, s)),
                  value: s,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
