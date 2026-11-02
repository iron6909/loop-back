// 添加音频对话框
//
// 支持两种模式：
// - 有 collectionId：添加音频后自动关联到指定合集
// - 无 collectionId：显示合集下拉框，可选择归入合集
//
// 支持选择一个音频文件添加。
// 添加成功后返回导入结果供调用方继续处理。
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:universal_io/io.dart';
import '../utils/app_data_dir.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import '../features/audio_import/audio_finalization_service.dart';
import '../features/audio_import/audio_import_cancel.dart';
import '../features/audio_import/audio_import_file_copy.dart';
import '../features/audio_import/audio_import_models.dart';
import '../features/audio_import/audio_registration_service.dart';
import '../features/audio_import/local_audio_file_picker.dart';
import '../features/audio_import/subtitle_pairing.dart';
import '../models/audio_item.dart';
import '../providers/collection_provider.dart';
import '../providers/audio_library_provider.dart';
import '../l10n/app_localizations.dart';
import '../services/app_logger.dart';
import '../utils/transcript_picker.dart';
import 'import_audio_selection_list.dart';

/// 已选中的音频文件信息
///
/// [file] 为原始选中文件（含缓存路径/字节）；复制到沙盒、算指纹等重活延后到点击
/// 「添加」时做，保证选择后预览秒出。[subtitleText]/[subtitleExt] 为同一次选择里
/// 配对到的同名字幕（已解码原始文本与扩展名 srt/vtt/lrc），无匹配或解码失败为 null；
/// 转 SRT 延后到入库时（需音频时长）。
typedef _PickedAudio = ({
  PlatformFile file,
  String name,
  String displayName,
  int fileSize,
  String? subtitleText,
  String? subtitleExt,
});

typedef _SavedPickedAudio = ({
  String path,
  String fileName,
  String audioSha256,
  String originalAudioSha256,
  bool created,
});

/// 内联错误提示种类
enum _AudioErrorKind { unsupportedFormat, noAudioSelected, generic }

/// 内联错误条数据
class _InlineError {
  final _AudioErrorKind kind;
  final String message;
  const _InlineError(this.kind, this.message);
}

/// 添加音频对话框
///
/// 返回值：
/// - `AudioImportOutcome` — 导入结果
/// - `null` — 用户取消
class AddAudioDialog extends ConsumerStatefulWidget {
  /// 合集 ID（为 null 时显示合集下拉框）
  final String? collectionId;
  final bool embedded;
  final AudioImportSourceType importSourceType;
  final bool preferDownloadsDirectory;

  /// 面板创建后是否立即唤起文件选择器（用于「点入口即选择」的流程）。
  final bool autoPickOnStart;

  /// 目录导入：直接使用已枚举的直接子项，不再唤起文件选择器。
  final PickedAudioDirectory? initialDirectory;

  /// 导入完成后的结果回调（目录导入需要在有结果后才创建合集）。
  final Future<void> Function(List<String> audioIds)? onImported;

  /// 目录导入完成后的收尾动作（由宿主关闭面板并回传新建合集）。
  final VoidCallback? onDone;

  /// 通知嵌入式导入流程的宿主：本地文件处理是否正在运行。
  final ValueChanged<bool>? onImportingChanged;

  /// 自动唤起的选择器被取消、且当前未选中任何文件时回调（供上层退回来源选择页）。
  final VoidCallback? onPickerDismissedEmpty;

  const AddAudioDialog({
    super.key,
    this.collectionId,
    this.embedded = false,
    this.importSourceType = AudioImportSourceType.local,
    this.preferDownloadsDirectory = true,
    this.autoPickOnStart = false,
    this.initialDirectory,
    this.onImported,
    this.onDone,
    this.onImportingChanged,
    this.onPickerDismissedEmpty,
  });

  @override
  ConsumerState<AddAudioDialog> createState() => _AddAudioDialogState();
}

class _AddAudioDialogState extends ConsumerState<AddAudioDialog> {
  final AndroidLocalAudioFilePicker _localAudioFilePicker =
      AndroidLocalAudioFilePicker();

  /// 已选中的音频文件列表
  List<_PickedAudio> _pickedFiles = [];

  bool _isLoading = false;
  bool _isCanceling = false;
  CancelToken? _cancelToken;
  String? _activeImportTraceId;
  String _activeImportStage = 'idle';

  /// 添加时的进度
  int _processedCount = 0;

  /// 导入列表单行状态，key 使用 [_pickedAudioId]，让本地导入与网盘导入共用同一套 UI。
  final Map<String, AudioImportSelectionStatus> _importStatuses = {};

  /// 重复跳过项对应的库中已有音频名。
  final Map<String, String> _duplicateExistingNames = {};

  /// 成功导入项最终是否带字幕；完成态优先读这里，避免和选择阶段配对状态不一致。
  final Map<String, bool> _addedSubtitleStates = {};

  /// 当前选择列表的完成汇总；不为空时底部主按钮切换为「完成」。
  AudioImportSelectionSummary? _importSummary;

  /// 已完成导入的原始结果，供非 embedded 调用方在点击「完成」后继续接收。
  AudioImportOutcome? _completedOutcome;

  /// 目录导入的新增或重复项最终音频 ID，按选择顺序去重后用于建合集。
  final Map<String, String> _directoryAudioIds = {};

  /// 合集创建失败时主按钮改为重试，避免重新复制已导入音频。
  bool _directoryCommitFailed = false;

  /// 用户选择的合集 ID（仅 collectionId == null 时使用）
  String? _selectedCollectionId;

  /// 内联错误状态（避免 SnackBar 被 dialog scrim 遮蔽）
  _InlineError? _error;
  Timer? _errorClearTimer;

  /// 文件选择器是否正在唤起中（用于展示占位加载态）
  bool _isPicking = false;

  /// 目录导入时被忽略的子目录与不支持文件数，只在汇总区展示。
  int _ignoredDirectories = 0;
  int _unsupportedCount = 0;

  @override
  void initState() {
    super.initState();
    final directory = widget.initialDirectory;
    if (directory != null) {
      // 目录已枚举完成，直接进入确认列表；不需要再唤起选择器。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyDirectory(directory);
      });
      return;
    }
    // 「点入口即选择」：面板挂载后立即唤起系统文件选择器。
    if (widget.autoPickOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pickAudioFiles();
      });
    }
  }

  @override
  void dispose() {
    _errorClearTimer?.cancel();
    _cancelToken?.cancel('local import dialog disposed');
    super.dispose();
  }

  /// 显示内联错误条，6 秒后自动消失，重复触发重置倒计时
  void _showInlineError(_InlineError err) {
    _errorClearTimer?.cancel();
    setState(() => _error = err);
    _errorClearTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted) return;
      setState(() => _error = null);
    });
  }

  void _dismissInlineError() {
    _errorClearTimer?.cancel();
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    if (widget.embedded) {
      return _buildEmbeddedPanel(l10n, colorScheme);
    }

    // 自适应宽度：默认 AlertDialog 在窄屏（如 360dp 手机）会被 insetPadding 挤到
    // 极窄，文件名只能显示省略号；这里把侧边 inset 收紧到 16dp，并按屏幕宽度的
    // 90% 取宽（封顶 560dp，符合 Material 3 dialog 上限）。
    final screenWidth = MediaQuery.of(context).size.width;
    final dialogWidth = (screenWidth - 32).clamp(280.0, 560.0);
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(
        widget.collectionId != null ? l10n.addAudioToCollection : l10n.addAudio,
        textAlign: TextAlign.center,
      ),
      content: SizedBox(
        width: dialogWidth,
        child: _buildContent(l10n, colorScheme),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actions: [_buildActionsRow(l10n)],
    );
  }

  Widget _buildEmbeddedPanel(AppLocalizations l10n, ColorScheme colorScheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildContent(l10n, colorScheme, maxFileListHeight: 220),
        const SizedBox(height: 20),
        _buildActionsRow(l10n),
      ],
    );
  }

  Widget _buildActionsRow(AppLocalizations l10n) {
    if (_importSummary != null) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: _isLoading
              ? null
              : _directoryCommitFailed
              ? _finishDirectory
              : widget.onDone ??
                    () => Navigator.pop(context, _completedOutcome),
          child: Text(_directoryCommitFailed ? l10n.retry : l10n.done),
        ),
      );
    }

    // embedded 面板内没有独立的「选择音频文件」按钮（那个只在独立弹窗里渲染），
    // 空列表时若主按钮仍是禁用的「导入」，用户就没有任何重新唤起选择器的入口了
    // ——只选中字幕、或把已选文件全删掉都会落到这个状态。此时主按钮改为选择入口。
    if (widget.embedded && _pickedFiles.isEmpty) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: _isPicking ? null : _pickAudioFiles,
          child: Text(l10n.selectAudioFile),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: _isLoading
            ? _isCanceling
                  ? null
                  : _cancelImport
            : _pickedFiles.isEmpty
            ? null
            : _addAudio,
        child: _isLoading
            ? Text(_isCanceling ? l10n.cancelingImport : l10n.cancelImport)
            : Text(
                _pickedFiles.isEmpty
                    ? l10n.importAudioShort
                    : l10n.importAudioAndSubtitleCount(
                        _pickedFiles.length,
                        _pickedFiles
                            .where((file) => file.subtitleText != null)
                            .length,
                      ),
              ),
      ),
    );
  }

  Widget _buildContent(
    AppLocalizations l10n,
    ColorScheme colorScheme, {
    double maxFileListHeight = 240,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // embedded 流程由来源选择页直接唤起选择器，面板内不再展示选择按钮与网盘提示，
        // 只呈现已选文件列表。非 embedded（独立弹窗）仍保留手动选择入口。
        if (!widget.embedded) _buildSelectAudioFileButton(l10n, colorScheme),
        // 选择器唤起中且尚无已选文件：展示占位加载态，避免空白面板。
        if (widget.embedded && _isPicking && _pickedFiles.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
        // 内联错误提示（淡入 + 上滑，6 秒自动消失）
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, -0.08),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: _error == null
                ? const SizedBox(
                    key: ValueKey('no-err'),
                    width: double.infinity,
                  )
                : Padding(
                    key: ValueKey(_error!.message),
                    padding: const EdgeInsets.only(top: 12),
                    child: _buildInlineErrorCard(
                      Theme.of(context),
                      l10n,
                      _error!,
                    ),
                  ),
          ),
        ),
        // 已选文件列表
        if (_pickedFiles.isNotEmpty) ...[
          const SizedBox(height: 12),
          ImportAudioSelectionList(
            items: [
              for (var i = 0; i < _pickedFiles.length; i++)
                _selectionItemFor(_pickedFiles[i], i),
            ],
            progress: _selectionProgress(l10n),
            summary: _importSummary,
            onRemove: _isLoading || _importSummary != null
                ? null
                : _removePickedAudio,
            maxHeight: maxFileListHeight,
          ),
        ],
        if (_importSummary case final summary?
            when widget.initialDirectory != null &&
                summary.addedCount == 0 &&
                summary.skippedCount > 0 &&
                summary.failedCount == 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(l10n.folderAllDuplicates),
          ),
        // 无 collectionId 时显示合集下拉框
        if (widget.collectionId == null && widget.initialDirectory == null) ...[
          const SizedBox(height: 16),
          _buildCollectionDropdown(l10n),
        ],
      ],
    );
  }

  AudioImportSelectionProgress? _selectionProgress(AppLocalizations l10n) {
    if (!_isLoading || _pickedFiles.length <= 1) return null;
    final currentIndex = _processedCount.clamp(0, _pickedFiles.length - 1);
    final file = _pickedFiles[currentIndex];
    return AudioImportSelectionProgress(
      value: _processedCount / _pickedFiles.length,
      label: l10n.importingFileProgress(
        _processedCount + 1,
        _pickedFiles.length,
        file.displayName,
      ),
    );
  }

  AudioImportSelectionItem _selectionItemFor(_PickedAudio file, int index) {
    final id = _pickedAudioId(file, index);
    return AudioImportSelectionItem(
      id: id,
      displayName: file.displayName,
      fileSize: file.fileSize,
      hasSubtitle: _addedSubtitleStates[id] ?? file.subtitleText != null,
      isVideo: isVideoImportExtension(path.extension(file.displayName)),
      status: _importStatuses[id] ?? AudioImportSelectionStatus.pending,
      duplicateExistingName: _duplicateExistingNames[id],
    );
  }

  String _pickedAudioId(_PickedAudio file, int index) {
    return file.file.identifier ??
        file.file.path ??
        '${file.displayName}-$index';
  }

  void _removePickedAudio(String id) {
    if (_isLoading || _importSummary != null) return;
    final next = <_PickedAudio>[];
    for (var i = 0; i < _pickedFiles.length; i++) {
      final file = _pickedFiles[i];
      if (_pickedAudioId(file, i) != id) next.add(file);
    }
    setState(() {
      _pickedFiles = next;
      _processedCount = 0;
      _importStatuses.clear();
      _duplicateExistingNames.clear();
      _addedSubtitleStates.clear();
      _completedOutcome = null;
      _importSummary = null;
    });
  }

  /// 构建本地音频选择入口，保留明确按钮语义并弱化相对底部主操作的层级。
  Widget _buildSelectAudioFileButton(
    AppLocalizations l10n,
    ColorScheme colorScheme,
  ) {
    return SizedBox(
      key: const ValueKey('select-audio-file-button'),
      width: double.infinity,
      height: 56,
      child: FilledButton.tonalIcon(
        onPressed: _isLoading ? null : _pickAudioFiles,
        style: FilledButton.styleFrom(
          foregroundColor: colorScheme.onSecondaryContainer,
          backgroundColor: colorScheme.secondaryContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        icon: const Icon(Icons.audio_file_outlined),
        label: Text(
          l10n.selectAudioFile,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// 内联错误提示卡片（与 ManageSubtitlesSheet 视觉一致：浅灰描边 + 橙色图标徽章）
  Widget _buildInlineErrorCard(
    ThemeData theme,
    AppLocalizations l10n,
    _InlineError err,
  ) {
    final colorScheme = theme.colorScheme;
    final accent = Colors.orange.shade700;

    final (IconData icon, String title) = switch (err.kind) {
      _AudioErrorKind.unsupportedFormat => (
        Icons.audiotrack_outlined,
        l10n.audioErrorUnsupportedTitle,
      ),
      _AudioErrorKind.noAudioSelected => (
        Icons.audiotrack_outlined,
        l10n.audioErrorNoAudioTitle,
      ),
      _AudioErrorKind.generic => (
        Icons.error_outline,
        l10n.audioErrorGenericTitle,
      ),
    };

    return Semantics(
      liveRegion: true,
      container: true,
      label: '$title. ${err.message}',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colorScheme.outlineVariant, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 第一行：图标 + 标题 + 关闭
            Row(
              children: [
                Icon(icon, size: 18, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                      height: 1.2,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _dismissInlineError,
                  icon: const Icon(Icons.close, size: 18),
                  color: colorScheme.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                ),
              ],
            ),
            // 第二行：详细描述（与标题左对齐，占满剩余宽度）
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 2, 4, 0),
              child: Text(
                err.message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建合集下拉选择框
  ///
  /// 社区合集（[Collection.isCommunity]）由远端定义，用户不能向其中添加自有音频，
  /// 因此下拉框只展示本地合集。
  Widget _buildCollectionDropdown(AppLocalizations l10n) {
    final collections = ref
        .watch(collectionListProvider)
        .rawCollections
        .where((c) => !c.isCommunity)
        .toList();
    return DropdownButtonFormField<String?>(
      initialValue: _selectedCollectionId,
      decoration: InputDecoration(
        labelText: l10n.selectCollection,
        isDense: true,
      ),
      items: [
        DropdownMenuItem<String?>(value: null, child: Text(l10n.noCollection)),
        ...collections.map(
          (c) => DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
        ),
      ],
      onChanged: _isLoading
          ? null
          : (value) => setState(() => _selectedCollectionId = value),
    );
  }

  /// 选择音频文件（可同时选中同名字幕自动配对）
  ///
  /// 选择器放行「音频 + 字幕」并集，用户一次把成对的音频和字幕都选上；App 在选中集合内
  /// 按去扩展名同名把字幕配对到音频，导入时一并入库，免去逐个手动上传字幕。
  Future<void> _pickAudioFiles() async {
    if (mounted) setState(() => _isPicking = true);
    try {
      final result = await _showAudioFilePicker();
      if (result == null || result.files.isEmpty) {
        // 未选中任何文件：若当前也无已选文件，通知上层退回来源选择页。
        if (_pickedFiles.isEmpty) widget.onPickerDismissedEmpty?.call();
        return;
      }

      await _applyFiles(result.files);
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        _showInlineError(
          _InlineError(
            _AudioErrorKind.generic,
            '${l10n.pickAudioFileFailed}: $e',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  /// 目录直接子项沿用文件导入的分类与字幕配对，不预先复制音频。
  Future<void> _applyDirectory(PickedAudioDirectory directory) => _applyFiles(
    directory.files,
    ignoredDirectories: directory.ignoredDirectories,
    unsupportedCount: directory.unsupportedCount,
  );

  /// 一批文件先生成确认列表；复制与入库延后至用户点击导入。
  Future<void> _applyFiles(
    List<PlatformFile> files, {
    int ignoredDirectories = 0,
    int unsupportedCount = 0,
  }) async {
    // 1. 建立文件名 → 文件映射，并按扩展名分类（音频 / 字幕 / 不支持）。
    final byName = <String, PlatformFile>{for (final f in files) f.name: f};
    final classification = classifyImportFiles(byName.keys);
    // 音频在前、视频在后，一并进入后续同名字幕配对与入库流程。
    final audioFiles = [
      for (final n in classification.audioNames) byName[n]!,
      for (final n in classification.videoNames) byName[n]!,
    ];
    final subtitleFiles = <String, PlatformFile>{
      for (final n in classification.subtitleNames) n: byName[n]!,
    };
    final rejectedExts = classification.rejectedExtensions;

    // 2. 同名配对（音频文件名 → 字幕文件名）。
    final pairing = matchSubtitlesForAudios(byName.keys);

    // 3. 配对到的字幕就地解码（文本很小，文本+扩展名留到入库时转 SRT）。
    //    音频不在此复制/算指纹——那些重活延后到点击「添加」时做，保证预览秒出。
    final List<_PickedAudio> picked = [];
    var matchedCount = 0;
    for (final file in audioFiles) {
      final sourcePath = file.path;
      final sourceName = file.name.isNotEmpty
          ? file.name
          : sourcePath == null
          ? 'file'
          : path.basename(sourcePath);

      String? subtitleText;
      String? subtitleExt;
      final matchedName = pairing[file.name];
      final subtitleFile = matchedName == null
          ? null
          : subtitleFiles[matchedName];
      if (matchedName != null && subtitleFile != null) {
        try {
          final bytes = await _readPlatformFileBytes(subtitleFile);
          // 仅解码取文本；具体格式（srt/vtt/lrc）解析交给入库时按扩展名处理。
          final decoded = await decodeTranscriptBytes(bytes);
          subtitleText = decoded.text;
          subtitleExt = _extOf(matchedName);
          matchedCount++;
        } catch (e) {
          // 字幕解码失败不影响音频导入，仅记录。
          AppLogger.log(
            'AudioImport',
            'decode subtitle "$matchedName" for "${file.name}" failed: $e',
          );
        }
      }

      picked.add((
        file: file,
        name: path.basenameWithoutExtension(sourceName),
        displayName: sourceName,
        fileSize: file.size,
        subtitleText: subtitleText,
        subtitleExt: subtitleExt,
      ));
    }

    AppLogger.log(
      'AudioImport',
      'picked audios=${audioFiles.length} subtitles=${subtitleFiles.length} '
          'matched=$matchedCount rejected=${rejectedExts.length}',
    );

    if (!mounted) return;
    if (rejectedExts.isNotEmpty) {
      final l10n = AppLocalizations.of(context)!;
      final extList = rejectedExts.toSet().map((e) => '.$e').join(', ');
      _showInlineError(
        _InlineError(
          _AudioErrorKind.unsupportedFormat,
          l10n.audioUnsupportedFormat(extList),
        ),
      );
    } else if (picked.isEmpty) {
      // 只选中了字幕（字幕不能单独导入）：不给提示的话面板会一直空着，
      // 用户不知道为什么什么都没发生。有不支持格式时上面那条已经解释过了，
      // 两条错误只能显示一条，不叠加。
      final l10n = AppLocalizations.of(context)!;
      _showInlineError(
        _InlineError(
          _AudioErrorKind.noAudioSelected,
          l10n.audioNoAudioSelected,
        ),
      );
    }
    if (picked.isNotEmpty) {
      setState(() {
        _pickedFiles = picked;
        _ignoredDirectories = ignoredDirectories;
        _unsupportedCount = unsupportedCount + rejectedExts.length;
        _directoryAudioIds.clear();
        _directoryCommitFailed = false;
        _processedCount = 0;
        _importStatuses.clear();
        _duplicateExistingNames.clear();
        _addedSubtitleStates.clear();
        _importSummary = null;
        _completedOutcome = null;
      });
    }
  }

  /// 弹出系统文件选择器，放行「音频 + 字幕」扩展名并集。
  Future<FilePickerResult?> _showAudioFilePicker() {
    final allowed = [
      ...audioImportExtensions,
      ...videoFileExtensions,
      ...subtitleImportExtensions,
    ];
    if (!kIsWeb && Platform.isAndroid) {
      // Android SAF 在 FileType.custom + 多扩展名场景会按精确 MIME 匹配，
      // 导致 m4a/flac 等被设备索引成非标 MIME 的文件被灰掉、无法选中；且 FileType.audio
      // 会隐藏字幕文件。故不做系统端过滤，选中后我们自己按白名单过滤。
      // 走自家 SAF 通道而非 file_picker：后者在 DocumentsProvider 缺 DISPLAY_NAME 时
      // 会回传 null 文件名并在插件内部抛类型异常，见 [AndroidLocalAudioFilePicker]。
      return _localAudioFilePicker.pickFiles();
    }
    if (!kIsWeb && Platform.isIOS) {
      return FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: allowed,
        allowMultiple: true,
      );
    }
    return _getDownloadsDirectory().then((initialDir) {
      return FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: allowed,
        allowMultiple: true,
        initialDirectory:
            widget.preferDownloadsDirectory && !kIsWeb && Platform.isMacOS
            ? initialDir
            : null,
      );
    });
  }

  /// 读取选中文件的字节（路径 / bytes / content URI / 流四种来源）。
  ///
  /// 只服务字幕（KB 级）。Android 的选中项没有文件路径，只有 content URI，
  /// 走原生通道整体读入内存；音频不能走这里，见 [_savePickedFileToSandbox]。
  Future<Uint8List> _readPlatformFileBytes(PlatformFile file) async {
    final sourcePath = file.path;
    if (sourcePath != null) return File(sourcePath).readAsBytes();
    final bytes = file.bytes;
    if (bytes != null) return bytes;
    final identifier = file.identifier;
    if (identifier != null &&
        !kIsWeb &&
        (Platform.isAndroid || widget.initialDirectory != null)) {
      return _localAudioFilePicker.readBytes(identifier);
    }
    final readStream = file.readStream;
    if (readStream != null) {
      final chunks = <int>[];
      await for (final chunk in readStream) {
        chunks.addAll(chunk);
      }
      return Uint8List.fromList(chunks);
    }
    throw Exception('Unable to access picked subtitle file');
  }

  /// 提取文件扩展名（小写、不含点）。
  static String _extOf(String name) =>
      path.extension(name).replaceFirst('.', '').toLowerCase();

  Future<String?> _getDownloadsDirectory() async {
    try {
      final home = Platform.environment['HOME'];
      if (home == null) return null;
      return path.join(home, 'Downloads');
    } catch (_) {
      return null;
    }
  }

  /// 保存文件到应用沙盒，返回相对于数据目录的相对路径
  Future<_SavedPickedAudio> _savePickedFileToSandbox(
    PlatformFile file,
    String subdir,
    CancelToken cancelToken,
  ) async {
    final traceId = cancelToken.hashCode.toRadixString(16);
    final dataDir = await getAppDataDirectory();
    cancelToken.throwIfCanceled();
    final tmpDir = Directory(path.join(dataDir.path, 'tmp', 'audio_import'));
    await tmpDir.create(recursive: true);

    final bytes = file.bytes;
    final readStream = file.readStream;
    final identifier = file.identifier;
    final sourcePath = file.path;
    final baseName = file.name.isNotEmpty
        ? file.name
        : sourcePath == null
        ? 'file'
        : path.basename(sourcePath);

    final tmpName =
        '${DateTime.now().microsecondsSinceEpoch}-${path.basename(baseName)}';
    final tmpPath = path.join(tmpDir.path, tmpName);
    final tempFile = File(tmpPath);
    FinalizedAudio? finalized;
    final copyStopwatch = Stopwatch()..start();
    final sourceType = sourcePath != null
        ? 'path'
        : identifier != null && !kIsWeb && Platform.isAndroid
        ? 'android-uri'
        : bytes != null
        ? 'bytes'
        : readStream != null
        ? 'stream'
        : 'unavailable';

    try {
      AppLogger.log(
        'AudioImportLocal',
        'copy_begin trace=$traceId source=$sourceType size=${file.size}',
      );
      // 先复制到临时目录；取消时关闭当前流并删除半成品。
      if (sourcePath != null) {
        await copyAudioImportStreamToFile(
          source: File(sourcePath).openRead(),
          destination: tempFile,
          cancelToken: cancelToken,
        );
      } else if (identifier != null &&
          !kIsWeb &&
          (Platform.isAndroid || widget.initialDirectory != null)) {
        await _localAudioFilePicker.copyToFile(
          identifier,
          tmpPath,
          cancelToken: cancelToken,
        );
      } else if (bytes != null) {
        await copyAudioImportStreamToFile(
          source: Stream<List<int>>.fromIterable(_chunkBytes(bytes)),
          destination: tempFile,
          cancelToken: cancelToken,
        );
      } else if (readStream != null) {
        await copyAudioImportStreamToFile(
          source: readStream,
          destination: tempFile,
          cancelToken: cancelToken,
        );
      } else {
        throw Exception('Unable to access picked file');
      }

      AppLogger.log(
        'AudioImportLocal',
        'copy_complete trace=$traceId bytes=${await tempFile.length()} '
            'elapsed_ms=${copyStopwatch.elapsedMilliseconds}',
      );
      _activeImportStage = 'fingerprint';
      AppLogger.log('AudioImportLocal', 'finalize_begin trace=$traceId');
      cancelToken.throwIfCanceled();
      finalized = await AudioFinalizationService().finalize(
        dataDir: dataDir,
        tempRelativePath: path.join('tmp', 'audio_import', tmpName),
        targetSubdir: subdir,
        cancelToken: cancelToken,
      );
      cancelToken.throwIfCanceled();
      AppLogger.log(
        'AudioImportLocal',
        'finalize_complete trace=$traceId created=${finalized.created}',
      );

      return (
        path: finalized.relativePath,
        fileName: path.basename(finalized.relativePath),
        audioSha256: finalized.sha256,
        originalAudioSha256: finalized.originalSha256,
        created: finalized.created,
      );
    } catch (error) {
      AppLogger.log(
        'AudioImportLocal',
        'save_failed trace=$traceId stage=$_activeImportStage '
            'canceled=${cancelToken.isCancelled} error=${error.runtimeType}',
      );
      await _deleteIfExists(tempFile);
      final saved = finalized;
      if (saved != null && saved.created) {
        await _deleteIfExists(
          File(path.join(dataDir.path, saved.relativePath)),
        );
      }
      rethrow;
    }
  }

  Iterable<List<int>> _chunkBytes(Uint8List bytes) sync* {
    const chunkSize = 64 * 1024;
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, bytes.length);
      yield bytes.sublist(offset, end);
    }
  }

  /// 若该音频配对到了字幕且尚无字幕，则按音频时长转 SRT 并入库。
  ///
  /// 字幕入库失败不影响音频本身（音频已注册）；返回值反映最终字幕状态，供完成页判断。
  Future<AudioItem> _attachPairedSubtitle(
    AudioItem item,
    _PickedAudio file,
  ) async {
    final subtitleText = file.subtitleText;
    final subtitleExt = file.subtitleExt;
    if (subtitleText == null || subtitleExt == null || item.hasTranscript) {
      return item;
    }
    try {
      await importLocalSubtitle(
        ref,
        item,
        text: subtitleText,
        ext: subtitleExt,
      );
      AppLogger.log(
        'AudioImport',
        'attached subtitle to "${item.name}" (ext=$subtitleExt)',
      );
      return item.copyWith(transcriptSource: TranscriptSource.local);
    } catch (e) {
      AppLogger.log(
        'AudioImport',
        'attach subtitle to "${item.name}" failed: $e',
      );
      return item;
    }
  }

  Future<void> _deleteIfExists(File file) async {
    if (!await file.exists()) return;
    try {
      await file.delete();
    } catch (_) {}
  }

  /// 添加音频
  Future<void> _addAudio() async {
    // 重入守卫：_isLoading 同步置位前的窗口内若重复点击会重复入库，这里直接拦截。
    if (_pickedFiles.isEmpty || _isLoading) return;

    final l10n = AppLocalizations.of(context)!;
    final collectionId = widget.collectionId ?? _selectedCollectionId;
    final library = ref.read(audioLibraryProvider.notifier);
    final collectionList = ref.read(collectionListProvider.notifier);
    final registrationService = AudioRegistrationService();
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    final traceId = cancelToken.hashCode.toRadixString(16);
    _activeImportTraceId = traceId;
    _activeImportStage = 'prepare';

    final selectedFiles = [
      for (var i = 0; i < _pickedFiles.length; i++)
        if (_importStatuses[_pickedAudioId(_pickedFiles[i], i)] !=
                AudioImportSelectionStatus.added &&
            _importStatuses[_pickedAudioId(_pickedFiles[i], i)] !=
                AudioImportSelectionStatus.skipped)
          (file: _pickedFiles[i], index: i),
    ];
    if (selectedFiles.isEmpty) {
      _cancelToken = null;
      return;
    }

    setState(() {
      _isLoading = true;
      _isCanceling = false;
      _processedCount = 0;
      _importSummary = null;
      _completedOutcome = null;
      for (var i = 0; i < _pickedFiles.length; i++) {
        _importStatuses.putIfAbsent(
          _pickedAudioId(_pickedFiles[i], i),
          () => AudioImportSelectionStatus.pending,
        );
      }
    });
    widget.onImportingChanged?.call(true);
    AppLogger.log(
      'AudioImportLocal',
      'start trace=$traceId files=${selectedFiles.length} '
          'bytes=${selectedFiles.fold<int>(0, (sum, item) => sum + item.file.file.size)}',
    );

    final List<AudioItem> results = [];
    // 跳过的重复项：本次导入名 + 与之重复的库中已有条目名。
    final List<AudioImportDuplicate> skippedDuplicates = [];
    String? currentItemId;
    int? currentItemIndex;
    var canceled = false;

    try {
      final dataDir = await getAppDataDirectory();

      for (var i = 0; i < selectedFiles.length; i++) {
        cancelToken.throwIfCanceled();
        final selected = selectedFiles[i];
        final file = selected.file;
        final itemId = _pickedAudioId(file, selected.index);
        currentItemId = itemId;
        currentItemIndex = i + 1;
        if (!mounted) return;
        setState(() {
          _importStatuses[itemId] = AudioImportSelectionStatus.importing;
        });
        _activeImportStage = 'copy';
        AppLogger.log(
          'AudioImportLocal',
          'file_begin trace=$traceId index=${i + 1}/${selectedFiles.length} '
              'size=${file.file.size}',
        );

        try {
          // 落沙盒 + 算内容指纹（重活）在此进行，受下方进度条覆盖。
          // 视频落 videos/、音频落 audios/，按扩展名区分，目录职责清晰。
          final ext = path
              .extension(file.displayName)
              .replaceFirst('.', '')
              .toLowerCase();
          final subdir = isVideoImportExtension(ext) ? 'videos' : 'audios';
          final saved = await _savePickedFileToSandbox(
            file.file,
            subdir,
            cancelToken,
          );
          _activeImportStage = 'registration';
          AppLogger.log(
            'AudioImportLocal',
            'registration_begin trace=$traceId index=${i + 1}',
          );
          final AudioRegistrationResult result;
          try {
            result = await registrationService.registerSandboxedAudio(
              input: SandboxedAudioRegistrationInput(
                name: file.name,
                relativePath: saved.path,
                importSourceType: widget.importSourceType,
                audioSha256: saved.audioSha256,
                originalAudioSha256: saved.originalAudioSha256,
              ),
              audioLibrary: library,
              audioLibraryState: ref.read(audioLibraryProvider),
              collectionList: collectionList,
              collectionState: ref.read(collectionListProvider),
              collectionId: collectionId,
              cancelToken: cancelToken,
            );
          } on DioException catch (error) {
            if (!CancelToken.isCancel(error)) rethrow;
            if (saved.created) {
              await _deleteIfExists(File(path.join(dataDir.path, saved.path)));
            }
            setState(() {
              _importStatuses[itemId] = AudioImportSelectionStatus.pending;
            });
            canceled = true;
            break;
          }

          switch (result) {
            case AudioRegistrationAdded(:final item):
              if (saved.created && item.audioPath != saved.path) {
                await _deleteIfExists(
                  File(path.join(dataDir.path, saved.path)),
                );
              }
              final importedItem = await _attachPairedSubtitle(item, file);
              _directoryAudioIds[itemId] = item.id;
              results.add(importedItem);
              if (!mounted) return;
              setState(() {
                _importStatuses[itemId] = AudioImportSelectionStatus.added;
                _addedSubtitleStates[itemId] =
                    importedItem.transcriptSource == TranscriptSource.local;
              });
            case AudioRegistrationDuplicate(
              :final attemptedName,
              :final existingName,
            ):
              if (saved.created) {
                await _deleteIfExists(
                  File(path.join(dataDir.path, saved.path)),
                );
              }
              final existing = ref
                  .read(audioLibraryProvider)
                  .audioItems
                  .where(
                    (item) =>
                        item.originalAudioSha256 == saved.originalAudioSha256,
                  )
                  .firstOrNull;
              if (existing != null) _directoryAudioIds[itemId] = existing.id;
              skippedDuplicates.add((
                attempted: attemptedName,
                existing: existingName,
              ));
              if (!mounted) return;
              setState(() {
                _importStatuses[itemId] = AudioImportSelectionStatus.skipped;
                _duplicateExistingNames[itemId] = existingName;
              });
          }
        } catch (error) {
          if (widget.initialDirectory == null ||
              (error is DioException && CancelToken.isCancel(error))) {
            rethrow;
          }
          if (!mounted) return;
          // 一个文件损坏不阻断整个目录；保留成功项并继续下一个。
          setState(
            () => _importStatuses[itemId] = AudioImportSelectionStatus.failed,
          );
          _showInlineError(
            _InlineError(
              _AudioErrorKind.generic,
              '${file.displayName}: ${l10n.addAudioFailed}',
            ),
          );
        }
        AppLogger.log(
          'AudioImportLocal',
          'file_complete trace=$traceId index=${i + 1} '
              'status=${_importStatuses[itemId]?.name}',
        );

        if (!mounted) return;
        setState(() => _processedCount = i + 1);
        currentItemId = null;
        currentItemIndex = null;
        if (cancelToken.isCancelled) {
          canceled = true;
          break;
        }
      }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        canceled = true;
        AppLogger.log(
          'AudioImportLocal',
          'canceled trace=$traceId stage=$_activeImportStage '
              'index=${currentItemIndex ?? 'none'}',
        );
        final itemId = currentItemId;
        if (mounted && itemId != null) {
          setState(() {
            _importStatuses[itemId] = AudioImportSelectionStatus.pending;
          });
        }
      } else if (mounted) {
        AppLogger.log(
          'AudioImportLocal',
          'failed trace=$traceId stage=$_activeImportStage '
              'error=${e.runtimeType}',
        );
        final itemId = currentItemId;
        if (itemId != null) {
          setState(() {
            _importStatuses[itemId] = AudioImportSelectionStatus.failed;
          });
        }
        _showInlineError(
          _InlineError(_AudioErrorKind.generic, '${l10n.addAudioFailed}: $e'),
        );
      }
    } catch (e) {
      AppLogger.log(
        'AudioImportLocal',
        'failed trace=$traceId stage=$_activeImportStage '
            'canceled=${cancelToken.isCancelled} error=${e.runtimeType}',
      );
      if (mounted) {
        final itemId = currentItemId;
        if (itemId != null) {
          setState(() {
            _importStatuses[itemId] = AudioImportSelectionStatus.failed;
          });
        }
        _showInlineError(
          _InlineError(_AudioErrorKind.generic, '${l10n.addAudioFailed}: $e'),
        );
      } else {
        rethrow;
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isCanceling = false;
          if (identical(_cancelToken, cancelToken)) _cancelToken = null;
          _activeImportTraceId = null;
          _activeImportStage = 'idle';
        });
        widget.onImportingChanged?.call(false);
        AppLogger.log(
          'AudioImportLocal',
          'settled trace=$traceId canceled=${cancelToken.isCancelled} '
              'added=${results.length} skipped=${skippedDuplicates.length}',
        );
      }
    }

    if (!mounted) return;

    if (canceled || cancelToken.isCancelled) return;

    // 成功与跳过结果保留在当前选择列表内展示，便于用户返回继续选择其它文件导入。
    final outcome = (added: results, duplicates: skippedDuplicates);
    setState(() {
      _completedOutcome = outcome;
      _importSummary = AudioImportSelectionSummary(
        addedCount: results.length,
        subtitleCount: _addedSubtitleStates.values
            .where((hasSubtitle) => hasSubtitle)
            .length,
        skippedCount: skippedDuplicates.length,
        failedCount: _importStatuses.values
            .where((s) => s == AudioImportSelectionStatus.failed)
            .length,
        ignoredDirectories: _ignoredDirectories,
        unsupportedCount: _unsupportedCount,
      );
    });
    await _finishDirectory();
  }

  /// 合集提交失败只重试事务，保留已复制音频及其导入结果。
  Future<void> _finishDirectory() async {
    final onImported = widget.onImported;
    if (onImported == null || _directoryAudioIds.isEmpty || !mounted) return;
    setState(() => _isLoading = true);
    widget.onImportingChanged?.call(true);
    try {
      await onImported(_directoryAudioIds.values.toList());
      _directoryCommitFailed = false;
      if (mounted) _dismissInlineError();
    } catch (error) {
      _directoryCommitFailed = true;
      if (mounted) {
        _showInlineError(
          _InlineError(
            _AudioErrorKind.generic,
            '${AppLocalizations.of(context)!.addAudioFailed}: $error',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        widget.onImportingChanged?.call(false);
      }
    }
  }

  /// 取消当前本地导入；复制、指纹和未提交落盘会响应同一取消令牌。
  void _cancelImport() {
    final cancelToken = _cancelToken;
    if (cancelToken == null || cancelToken.isCancelled || !mounted) return;

    AppLogger.log(
      'AudioImportLocal',
      'cancel_requested trace=${_activeImportTraceId ?? 'unknown'} '
          'stage=$_activeImportStage',
    );

    setState(() {
      _isCanceling = true;
      // 取消信号发出后立即停止显示当前文件的导入动画；底层 I/O 仍会继续清理，
      // 完成前保持弹窗锁定，并用「正在取消」提示用户。
      for (final id in _importStatuses.keys.toList()) {
        if (_importStatuses[id] == AudioImportSelectionStatus.importing) {
          _importStatuses[id] = AudioImportSelectionStatus.pending;
        }
      }
    });
    cancelToken.cancel('user-cancelled');
  }
}
