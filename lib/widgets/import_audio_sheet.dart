import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../features/audio_import/audio_import_models.dart';
import '../features/audio_import/audio_import_provider.dart';
import '../features/audio_import/community_directory_import.dart';
import '../features/audio_import/last_import_directory_store.dart';
import '../features/audio_import/local_audio_file_picker.dart';
import '../database/providers.dart';
import '../providers/collection_provider.dart';
import '../features/audio_import/subtitle_pairing.dart';
import '../l10n/app_localizations.dart';
import '../services/app_logger.dart';
import '../theme/app_theme.dart';
import 'add_audio_dialog.dart';
import 'common/form_input_style.dart';
import 'common/secondary_action_button.dart';
import 'import_audio_selection_list.dart';
import 'media_type_icon.dart';

/// 显示统一的音频导入流程。
Future<String?> showImportAudioSheet(
  BuildContext context, {
  String? collectionId,
  bool directoryOnly = false,
}) async {
  final result = await showModalBottomSheet<Object?>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ImportAudioFlowSheet(
      collectionId: collectionId,
      directoryOnly: directoryOnly,
    ),
  );
  return result is String ? result : null;
}

enum _ImportStep {
  chooseSource,
  localFile,

  /// 有记住的文件夹时先问一句：继续用它，还是换一个。
  recentDirectory,
  localDirectory,

  /// 选中的文件夹里没有可导入音频：原地拒绝，可重选。
  directoryUnavailable,
  directUrl,
  completed,
}

class ImportAudioFlowSheet extends ConsumerStatefulWidget {
  const ImportAudioFlowSheet({
    super.key,
    this.collectionId,
    this.directoryOnly = false,
  });

  final String? collectionId;

  /// 创建合集时直接选目录；普通添加音频仍只提供文件和链接来源。
  final bool directoryOnly;

  @override
  ConsumerState<ImportAudioFlowSheet> createState() =>
      _ImportAudioFlowSheetState();
}

class _ImportAudioFlowSheetState extends ConsumerState<ImportAudioFlowSheet> {
  final _sheetScrollController = ScrollController();
  final _urlController = TextEditingController();
  _ImportStep _step = _ImportStep.chooseSource;
  AudioImportOutcome _outcome = (added: const [], duplicates: const []);
  bool _localImporting = false;
  PickedAudioDirectory? _directory;
  String? _directoryError;
  String? _createdCollectionId;

  /// 上次成功导入的文件夹（来自本地记忆）；为空时不经过「最近导入」页。
  RememberedImportDirectory? _remembered;

  /// 被拒绝的文件夹，用于在不可用页显示是哪一个文件夹。
  PickedAudioDirectory? _rejectedDirectory;

  /// 确认页汇总的计数与体积，来自目录计划。
  int _audioCount = 0;
  int _subtitleCount = 0;
  int _totalBytes = 0;

  /// 每次重新选目录都换 key，强制重建面板丢弃上一次的已选列表与状态。
  int _directorySelectionId = 0;

  @override
  void initState() {
    super.initState();
    if (widget.directoryOnly) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _startDirectoryImport(),
      );
    }
  }

  @override
  void dispose() {
    _sheetScrollController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(audioImportControllerProvider);
    final busy = _isBusy(state) || _localImporting;
    final importing = busy;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return PopScope(
      canPop: !importing,
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottomInset),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.86,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ImportHeader(
                  title: _titleFor(l10n),
                  showBack:
                      _step != _ImportStep.chooseSource &&
                      _step != _ImportStep.recentDirectory &&
                      !busy,
                  showClose: !importing,
                  onBack: _goBack,
                  onClose: () => Navigator.pop(context),
                ),
                const SizedBox(height: AppSpacing.m),
                if (_directoryError case final message?) ...[
                  _InlineInfoCard(message: message),
                  const SizedBox(height: AppSpacing.s),
                ],
                Flexible(
                  child: SingleChildScrollView(
                    controller: _sheetScrollController,
                    primary: false,
                    child: _buildStep(l10n, state),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _isBusy(AudioImportState state) {
    return state is AudioImportResolving ||
        state is AudioImportDownloading ||
        state is AudioImportSaving;
  }

  String _titleFor(AppLocalizations l10n) {
    return switch (_step) {
      _ImportStep.chooseSource => l10n.importAudio,
      _ImportStep.localFile => l10n.importAudioFromFile,
      _ImportStep.recentDirectory => l10n.importAudioFromFolder,
      _ImportStep.localDirectory => l10n.folderImportConfirmTitle,
      _ImportStep.directoryUnavailable => l10n.importAudioFromFolder,
      _ImportStep.directUrl => l10n.importAudioFromUrl,
      _ImportStep.completed => l10n.audioImportComplete,
    };
  }

  Widget _buildStep(AppLocalizations l10n, AudioImportState state) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: switch (_step) {
        _ImportStep.chooseSource => _ChooseSourcePanel(
          key: const ValueKey('choose-source'),
          onLocalFile: () => setState(() => _step = _ImportStep.localFile),
          onDirectUrl: () => setState(() => _step = _ImportStep.directUrl),
        ),
        _ImportStep.recentDirectory when _remembered != null =>
          _RecentDirectoryPanel(
            key: const ValueKey('recent-directory'),
            remembered: _remembered!,
            onOpen: _openRememberedDirectory,
            onChooseOther: _pickDirectory,
          ),
        // 记忆刚被清空、系统选择器正在唤起：不留一帧空白以外的旧内容。
        _ImportStep.recentDirectory => const SizedBox.shrink(),
        _ImportStep.localFile => AddAudioDialog(
          key: const ValueKey('local-file'),
          collectionId: widget.collectionId,
          embedded: true,
          autoPickOnStart: true,
          onImportingChanged: (isImporting) {
            if (_localImporting == isImporting || !mounted) return;
            setState(() => _localImporting = isImporting);
          },
          onPickerDismissedEmpty: _goBackToSource,
        ),
        _ImportStep.localDirectory => _FolderImportConfirmPanel(
          directory: _directory!,
          audioCount: _audioCount,
          subtitleCount: _subtitleCount,
          totalBytes: _totalBytes,
          onReplace: _pickDirectory,
          child: AddAudioDialog(
            key: ValueKey('local-directory-$_directorySelectionId'),
            embedded: true,
            initialDirectory: _directory,
            primaryActionLabel: l10n.folderImportCreateCollection(_audioCount),
            onImported: _handleDirectoryImported,
            onDone: () => Navigator.pop(context, _createdCollectionId),
            onImportingChanged: (isImporting) {
              if (_localImporting == isImporting || !mounted) return;
              setState(() => _localImporting = isImporting);
            },
          ),
        ),
        _ImportStep.directoryUnavailable => _FolderUnavailablePanel(
          key: const ValueKey('directory-unavailable'),
          directoryName: _rejectedDirectory?.name,
          onReselect: _pickDirectory,
          onCancel: () => Navigator.pop(context),
        ),
        _ImportStep.directUrl => _DirectUrlPanel(
          key: const ValueKey('direct-url'),
          controller: _urlController,
          state: state,
          onSubmit: _submitUrl,
          onBackIdle: _goBackToSource,
          onCancelBusy: _cancelUrlImport,
        ),
        _ImportStep.completed => _CompletedPanel(
          key: const ValueKey('completed'),
          outcome: _outcome,
          onDone: () => Navigator.pop(context),
        ),
      },
    );
  }

  /// 目录导入入口：有记忆的文件夹先给一键入口，否则直接唤起系统选择器。
  ///
  /// 系统选择器不支持指定落地位置，「默认上次的文件夹」只能由应用自己提供入口。
  Future<void> _startDirectoryImport() async {
    final remembered = ref.read(lastImportDirectoryStoreProvider).read();
    if (!mounted) return;
    if (remembered == null) {
      await _pickDirectory();
      return;
    }
    setState(() {
      _remembered = remembered;
      _step = _ImportStep.recentDirectory;
    });
  }

  /// 按已持久化的授权重新列出上次的文件夹；失效时静默清空并退回系统选择器。
  Future<void> _openRememberedDirectory() async {
    final remembered = _remembered;
    if (remembered == null) return;
    try {
      final directory = await AndroidLocalAudioFilePicker().listDirectory(
        remembered.uri,
      );
      if (!mounted) return;
      _applyDirectory(directory);
    } catch (error) {
      AppLogger.log(
        'AudioImport',
        'remembered_directory_unavailable error=${error.runtimeType}',
      );
      await ref.read(lastImportDirectoryStoreProvider).clear();
      if (!mounted) return;
      setState(() => _remembered = null);
      await _pickDirectory();
    }
  }

  /// 唤起系统目录选择器；取消时回到最近页（有记忆）或关闭面板。
  Future<void> _pickDirectory() async {
    try {
      final directory = await AndroidLocalAudioFilePicker().pickDirectory();
      if (!mounted) return;
      if (directory == null) {
        // 取消「更换」：已有可导入的文件夹时留在原确认页，不要关掉整个面板。
        if (_directory != null) return;
        if (_remembered != null) {
          setState(() => _step = _ImportStep.recentDirectory);
        } else if (widget.directoryOnly) {
          Navigator.pop(context);
        }
        return;
      }
      _applyDirectory(directory);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _directoryError =
            '${AppLocalizations.of(context)!.pickAudioFileFailed}: $error',
      );
    }
  }

  /// 目录计划：有音频进确认页，没有就停在不可用页并保留重选入口。
  void _applyDirectory(PickedAudioDirectory directory) {
    final plan = CommunityDirectoryImport(directory);
    if (plan.isEmpty) {
      setState(() {
        _directoryError = null;
        _directory = null;
        _rejectedDirectory = directory;
        _step = _ImportStep.directoryUnavailable;
      });
      return;
    }
    setState(() {
      _directory = PickedAudioDirectory(
        name: directory.name,
        files: plan.files,
        uri: directory.uri,
        ignoredDirectories: directory.ignoredDirectories,
        unsupportedCount: plan.unsupportedCount,
      );
      _directoryError = null;
      _rejectedDirectory = null;
      _audioCount = plan.audioCount;
      _subtitleCount = plan.files.length - plan.audioCount;
      _totalBytes = plan.files.fold(0, (sum, file) => sum + file.size);
      _createdCollectionId = null;
      _directorySelectionId++;
      _step = _ImportStep.localDirectory;
    });
  }

  Future<void> _handleDirectoryImported(List<String> audioIds) async {
    final directory = _directory;
    if (directory == null || audioIds.isEmpty) return;
    var createdId = _createdCollectionId;
    if (createdId == null) {
      createdId = await CommunityDirectoryImport(
        directory,
      ).commit(ref.read(appDatabaseProvider), audioIds);
      _createdCollectionId = createdId;
    }
    // 合集建成后才记住这个文件夹：下次点「从文件夹导入」一点就到。
    final uri = directory.uri;
    if (createdId != null && uri != null) {
      final remembered = RememberedImportDirectory(
        name: directory.name,
        uri: uri,
      );
      await ref.read(lastImportDirectoryStoreProvider).save(remembered);
      if (mounted) setState(() => _remembered = remembered);
    }
    await ref.read(collectionListProvider.notifier).loadCollections();
  }

  void _goBackToSource() {
    ref.read(audioImportControllerProvider.notifier).reset();
    setState(() => _step = _ImportStep.chooseSource);
  }

  void _goBack() {
    if (!widget.directoryOnly) {
      _goBackToSource();
      return;
    }
    final canReturnToRecent =
        _remembered != null &&
        (_step == _ImportStep.localDirectory ||
            _step == _ImportStep.directoryUnavailable);
    if (canReturnToRecent) {
      ref.read(audioImportControllerProvider.notifier).reset();
      setState(() {
        _directoryError = null;
        _step = _ImportStep.recentDirectory;
      });
      return;
    }
    Navigator.pop(context);
  }

  /// 切到独立完成页。
  ///
  /// 只服务链接导入：它一次只导一个文件、没有列表可展示结果；本地文件与目录导入
  /// 都把成功/跳过状态就地渲染在各自的已选列表里，不经过这里。
  void _handleImported(AudioImportOutcome outcome) {
    // 无任何结果（既没成功也没跳过）时不前进，停留原页供用户重选。
    if (outcome.added.isEmpty && outcome.duplicates.isEmpty) return;
    setState(() {
      _outcome = outcome;
      _step = _ImportStep.completed;
    });
  }

  Future<void> _submitUrl() async {
    final input = _urlController.text.trim();
    if (input.isEmpty) {
      ref.read(audioImportControllerProvider.notifier).reset();
      return;
    }
    final item = await ref
        .read(audioImportControllerProvider.notifier)
        .importFromUrl(input, collectionId: widget.collectionId);
    if (!mounted || item == null) return;
    _handleImported((added: [item], duplicates: const []));
  }

  Future<void> _cancelUrlImport() async {
    await ref.read(audioImportControllerProvider.notifier).cancel();
    if (!mounted) return;
    setState(() => _step = _ImportStep.directUrl);
  }
}

class _ImportHeader extends StatelessWidget {
  const _ImportHeader({
    required this.title,
    required this.showBack,
    this.showClose = true,
    required this.onBack,
    required this.onClose,
  });

  final String title;
  final bool showBack;
  final bool showClose;
  final VoidCallback onBack;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 40, maxWidth: 40),
              child: SizedBox(
                height: 40,
                child: !showBack && !showClose
                    ? const SizedBox(width: 40, height: 40)
                    : showBack
                    ? IconButton(
                        onPressed: onBack,
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).backButtonTooltip,
                        icon: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          size: 28,
                        ),
                        style: IconButton.styleFrom(
                          fixedSize: const Size(40, 40),
                          minimumSize: const Size(40, 40),
                          maximumSize: const Size(40, 40),
                          shape: const CircleBorder(),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: EdgeInsets.zero,
                        ),
                      )
                    : _HeaderIconButton(
                        icon: Icons.close,
                        onPressed: onClose,
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonTooltip,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: 22),
      style: IconButton.styleFrom(
        fixedSize: const Size(30, 30),
        minimumSize: const Size(30, 30),
        maximumSize: const Size(30, 30),
        shape: const CircleBorder(),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
        backgroundColor: Colors.transparent,
        disabledBackgroundColor: Colors.transparent,
        hoverColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.72),
        highlightColor: colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.52,
        ),
      ),
    );
  }
}

class _ChooseSourcePanel extends StatelessWidget {
  const _ChooseSourcePanel({
    super.key,
    required this.onLocalFile,
    required this.onDirectUrl,
  });

  final VoidCallback onLocalFile;
  final VoidCallback onDirectUrl;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ImportOptionTile(
          key: const ValueKey('import-option-local-file'),
          icon: Icons.audio_file_outlined,
          title: l10n.importAudioFromFile,
          onTap: onLocalFile,
        ),
        const SizedBox(height: 8),
        _ImportOptionTile(
          key: const ValueKey('import-option-direct-url'),
          icon: Icons.link,
          title: l10n.importAudioFromUrl,
          description: l10n.importAudioFromUrlDescription,
          onTap: onDirectUrl,
        ),
      ],
    );
  }
}

class _ImportOptionTile extends StatelessWidget {
  const _ImportOptionTile({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.description,
    required this.onTap,
  }) : assert(icon != null || leading != null);

  final IconData? icon;

  /// 自定义入口图标。用于保留品牌 SVG 原始形态。
  final Widget? leading;
  final String title;

  /// 可选说明文案，为 null 时不显示说明行。
  final String? description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.36),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: 34,
                height: 34,
                child: leading ?? Icon(icon, color: colorScheme.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (description != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        description!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// 目录导入：上次的文件夹一键入口 + 改选其他文件夹。
class _RecentDirectoryPanel extends StatelessWidget {
  const _RecentDirectoryPanel({
    super.key,
    required this.remembered,
    required this.onOpen,
    required this.onChooseOther,
  });

  final RememberedImportDirectory remembered;
  final VoidCallback onOpen;
  final VoidCallback onChooseOther;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.folderImportRecentLabel,
          style: theme.textTheme.labelMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Material(
          key: const ValueKey('remembered-directory'),
          color: colorScheme.primaryContainer.withValues(alpha: 0.35),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: colorScheme.primary.withValues(alpha: 0.28),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
              child: Row(
                children: [
                  Icon(Icons.folder_open_outlined, color: colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      remembered.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: colorScheme.primary),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            key: const ValueKey('choose-other-directory'),
            onPressed: onChooseOther,
            icon: const Icon(Icons.drive_file_move_outlined, size: 20),
            label: Text(l10n.folderImportChooseOther),
          ),
        ),
        const SizedBox(height: AppSpacing.m),
        const _FolderImportNotes(),
      ],
    );
  }
}

/// 挑选前与空目录时共用的格式 / 子目录说明，避免两处文案漂移。
class _FolderImportNotes extends StatelessWidget {
  const _FolderImportNotes();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      height: 1.45,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.folderImportSupportedFormats, style: style),
        const SizedBox(height: 4),
        Text(l10n.folderImportNoSubdirectories, style: style),
      ],
    );
  }
}

/// 确认页：文件夹身份 + 汇总 + 复用 AddAudioDialog 的列表与导入主操作。
class _FolderImportConfirmPanel extends StatelessWidget {
  const _FolderImportConfirmPanel({
    required this.directory,
    required this.audioCount,
    required this.subtitleCount,
    required this.totalBytes,
    required this.onReplace,
    required this.child,
  });

  final PickedAudioDirectory directory;
  final int audioCount;
  final int subtitleCount;
  final int totalBytes;
  final VoidCallback onReplace;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final skipped = <String>[
      if (directory.unsupportedCount > 0)
        l10n.folderUnsupportedFiles(directory.unsupportedCount),
      if (directory.ignoredDirectories > 0)
        l10n.folderIgnoredSubdirectories(directory.ignoredDirectories),
    ];
    final importDetail = [
      l10n.audioCount(audioCount),
      if (subtitleCount > 0) l10n.folderImportSubtitleCount(subtitleCount),
      formatImportFileSize(totalBytes),
    ].join(' · ');

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.folder_open_outlined,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                directory.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              key: const ValueKey('replace-directory'),
              onPressed: onReplace,
              child: Text(l10n.folderImportReplace),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SummaryRow(
                label: l10n.folderImportCollectionName,
                value: directory.name,
                valueWeight: FontWeight.w600,
              ),
              const SizedBox(height: 8),
              _SummaryRow(
                label: l10n.folderImportWillImport,
                value: importDetail,
              ),
              if (skipped.isNotEmpty) ...[
                const SizedBox(height: 8),
                _SummaryRow(
                  label: l10n.folderImportWillSkip,
                  value: skipped.join(' · '),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.m),
        child,
      ],
    );
  }
}

/// 汇总行：固定标签列 + 可换行内容。
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    this.valueWeight,
  });

  final String label;
  final String value;
  final FontWeight? valueWeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 62,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: valueWeight,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

/// 选中的文件夹没有可导入音频：不建合集、不进空列表，原地解释并可重选。
class _FolderUnavailablePanel extends StatelessWidget {
  const _FolderUnavailablePanel({
    super.key,
    this.directoryName,
    required this.onReselect,
    required this.onCancel,
  });

  final String? directoryName;
  final VoidCallback onReselect;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colorScheme.error.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.error_outline, color: colorScheme.error),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.folderEmptyNoAudio,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
        if (directoryName case final name?) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                Icons.folder_outlined,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.m),
        const _FolderImportNotes(),
        const SizedBox(height: AppSpacing.m),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton(
            key: const ValueKey('reselect-directory'),
            onPressed: onReselect,
            child: Text(l10n.folderImportChooseOther),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          height: 44,
          child: TextButton(onPressed: onCancel, child: Text(l10n.cancel)),
        ),
      ],
    );
  }
}

class _DirectUrlPanel extends StatefulWidget {
  const _DirectUrlPanel({
    super.key,
    required this.controller,
    required this.state,
    required this.onSubmit,
    required this.onBackIdle,
    required this.onCancelBusy,
  });

  final TextEditingController controller;
  final AudioImportState state;
  final VoidCallback onSubmit;
  final VoidCallback onBackIdle;
  final VoidCallback onCancelBusy;

  @override
  State<_DirectUrlPanel> createState() => _DirectUrlPanelState();
}

class _DirectUrlPanelState extends State<_DirectUrlPanel> {
  String? _clipboardError;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = widget.state;
    final busy =
        state is AudioImportResolving ||
        state is AudioImportDownloading ||
        state is AudioImportSaving;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.controller,
          enabled: !busy,
          autofocus: false,
          style: compactFormTextStyle(context),
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          decoration: compactFormInputDecoration(
            context,
            labelText: l10n.audioUrlLabel,
            hintText: l10n.audioUrlHint,
            suffixIcon: widget.controller.text.isEmpty || busy
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(widget.controller.clear),
                  ),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: busy ? null : (_) => widget.onSubmit(),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Spacer(),
            TextButton.icon(
              onPressed: busy ? null : () => _pasteFromClipboard(l10n),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.content_paste, size: 18),
              label: Text(l10n.pasteAudioLink),
            ),
          ],
        ),
        if (_clipboardError != null) ...[
          const SizedBox(height: 8),
          _InlineInfoCard(message: _clipboardError!),
        ],
        if (state is AudioImportFailed) ...[
          const SizedBox(height: 12),
          _ImportErrorCard(error: state.error),
        ],
        if (state is AudioImportDownloading) ...[
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: state.progress < 0 ? null : state.progress,
          ),
          const SizedBox(height: 8),
          Text(
            _progressLabel(l10n, state),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: AppSpacing.l),
        if (busy)
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: widget.onCancelBusy,
              child: Text(l10n.cancelImport),
            ),
          )
        else
          Row(
            children: [
              Expanded(
                child: SecondaryActionButton(
                  onPressed: widget.onBackIdle,
                  label: l10n.back,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: widget.controller.text.trim().isEmpty
                      ? null
                      : widget.onSubmit,
                  child: Text(l10n.downloadAndImportAudio),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Future<void> _pasteFromClipboard(AppLocalizations l10n) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;

    final text = data?.text?.trim() ?? '';
    if (!_isHttpUrl(text)) {
      setState(() => _clipboardError = l10n.audioClipboardNoValidLink);
      return;
    }

    widget.controller.text = text;
    widget.controller.selection = TextSelection.collapsed(offset: text.length);
    setState(() => _clipboardError = null);
  }

  bool _isHttpUrl(String text) {
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return false;
    return uri.scheme == 'http' || uri.scheme == 'https';
  }

  String _progressLabel(AppLocalizations l10n, AudioImportDownloading state) {
    final received = state.receivedBytes;
    final total = state.totalBytes;
    if (received == null || total == null || total <= 0) {
      return l10n.audioDownloadInProgress;
    }
    return '${l10n.audioDownloadInProgress} '
        '${(state.progress * 100).clamp(0, 100).toStringAsFixed(0)}%';
  }
}

class _InlineInfoCard extends StatelessWidget {
  const _InlineInfoCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      container: true,
      label: message,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: colorScheme.primary, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 导入完成页：统一展示成功入库的音频与因内容重复被跳过的项。
///
/// 成功与跳过结果合并到同一页，替代原先独立的重复项提示弹窗。
class _CompletedPanel extends StatelessWidget {
  const _CompletedPanel({
    super.key,
    required this.outcome,
    required this.onDone,
  });

  final AudioImportOutcome outcome;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final added = outcome.added;
    final duplicates = outcome.duplicates;
    // 成功导入数（含 0）与其中带字幕的数量。
    final addedCount = added.length;
    final subtitleCount = added.where((a) => a.hasTranscript).length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 成功入库摘要（始终显示，哪怕 0 个）。
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.check_circle, color: colorScheme.primary, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.audioImportedCount(addedCount),
                    style: theme.textTheme.titleMedium,
                  ),
                  // 成功导入数不为 0 时，再显示其中多少个带字幕。
                  if (addedCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        l10n.audioImportedWithSubtitleCount(subtitleCount),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        // 跳过的重复项列表（有跳过项才显示）。
        if (duplicates.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.l),
          Row(
            children: [
              Icon(
                Icons.skip_next_rounded,
                color: colorScheme.onSurfaceVariant,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.duplicatesSkipped(duplicates.length),
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.duplicatesSkippedDetail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          Flexible(child: _DuplicatesList(duplicates: duplicates)),
        ],
        const SizedBox(height: AppSpacing.l),
        SizedBox(
          width: double.infinity,
          child: FilledButton(onPressed: onDone, child: Text(l10n.done)),
        ),
      ],
    );
  }
}

/// 重复项限高滚动列表：单条为音频图标 + 导入名（+ 与哪个已有音频内容相同）。
class _DuplicatesList extends StatefulWidget {
  const _DuplicatesList({required this.duplicates});

  final List<AudioImportDuplicate> duplicates;

  @override
  State<_DuplicatesList> createState() => _DuplicatesListState();
}

class _DuplicatesListState extends State<_DuplicatesList> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Scrollbar(
        controller: _scrollController,
        child: ListView.separated(
          controller: _scrollController,
          primary: false,
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: widget.duplicates.length,
          separatorBuilder: (_, __) => Divider(
            height: 1,
            thickness: 1,
            indent: 44,
            color: colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
          itemBuilder: (_, i) =>
              _buildRow(theme, context, widget.duplicates[i]),
        ),
      ),
    );
  }

  Widget _buildRow(
    ThemeData theme,
    BuildContext context,
    AudioImportDuplicate dup,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MediaTypeIcon(
            isVideo: isVideoImportExtension(dup.attempted),
            size: 18,
            color: colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dup.attempted,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // 仅当导入名与已有名不同时，标注与哪个已有音频内容相同。
                if (dup.existing != dup.attempted)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      l10n.duplicateOfExisting(dup.existing),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.75,
                        ),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImportErrorCard extends StatelessWidget {
  const _ImportErrorCard({required this.error});

  final AudioImportException error;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final message = _messageFor(l10n, error);
    return Semantics(
      liveRegion: true,
      container: true,
      label: message,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: colorScheme.error, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _messageFor(AppLocalizations l10n, AudioImportException error) {
    return switch (error.code) {
      AudioImportFailureCode.invalidUrl ||
      AudioImportFailureCode.unsupportedScheme => l10n.audioUrlInvalid,
      AudioImportFailureCode.unsupportedFormat => l10n.audioUrlUnsupported,
      AudioImportFailureCode.notAudio => l10n.audioUrlNotDirectAudio,
      AudioImportFailureCode.duplicate => l10n.audioUrlDuplicate,
      AudioImportFailureCode.canceled => l10n.audioImportCanceled,
      AudioImportFailureCode.network ||
      AudioImportFailureCode.storage ||
      AudioImportFailureCode.unknown => l10n.audioDownloadFailed,
    };
  }
}
