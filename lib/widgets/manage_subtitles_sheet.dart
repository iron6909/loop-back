/// 管理字幕：播客字幕下载、英语本机转录与本地文件导入。
/// 转录任务由全局管理器持有，关闭弹窗不取消任务。
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:universal_io/io.dart';
import '../analytics/models/event_names.dart';
import '../database/providers.dart';
import '../features/podcast/podcast_transcript_downloader.dart';
import '../features/usage/usage_event.dart';
import '../features/usage/usage_providers.dart';
import '../providers/audio_sentences_provider.dart';
import '../providers/favorite_sentence_lifecycle_provider.dart';
import '../providers/learning_progress_provider.dart';
import '../providers/listening_practice/listening_practice_provider.dart';
import '../services/app_logger.dart';
import '../services/subtitle_parser.dart';
import '../utils/file_size.dart';
import '../utils/media_duration.dart';
import '../l10n/app_localizations.dart';
import '../models/audio_item.dart';
import '../providers/audio_library_provider.dart';
import '../providers/local_transcription_model_provider.dart';
import '../providers/local_transcription_task_provider.dart';
import '../router/app_router.dart';
import '../utils/transcript_picker.dart';
import 'asr_download_prompt_dialog.dart';
import 'transcription_options.dart';

part 'manage_subtitles_actions.dart';

enum _SubtitleAction { podcastDownload, localUpload, transcription }

class ManageSubtitlesSheet extends ConsumerStatefulWidget {
  const ManageSubtitlesSheet({
    super.key,
    required this.audioItem,
    this.transcriptContentPicker,
  });
  final AudioItem audioItem;
  final Future<TranscriptDecodeResult?> Function()? transcriptContentPicker;
  @override
  ConsumerState<ManageSubtitlesSheet> createState() =>
      _ManageSubtitlesSheetState();
}

class _ManageSubtitlesSheetState extends ConsumerState<ManageSubtitlesSheet> {
  _SubtitleAction _selectedAction = _SubtitleAction.transcription;
  bool _downloading = false;
  String? _error;
  Timer? _errorTimer;

  @override
  void initState() {
    super.initState();
    if (_hasPodcast(widget.audioItem)) {
      _selectedAction = _SubtitleAction.podcastDownload;
    }
    final task = ref.read(
      localTranscriptionTaskManagerProvider,
    )[widget.audioItem.id];
    if (task is LocalTranscriptionFailed ||
        task is LocalTranscriptionEmptyResult ||
        task is LocalTranscriptionConflict) {
      Future(() {
        if (mounted) {
          ref
              .read(localTranscriptionTaskManagerProvider.notifier)
              .clearState(widget.audioItem.id);
        }
      });
    }
  }

  @override
  void dispose() {
    _errorTimer?.cancel();
    super.dispose();
  }

  /// 错误保持十二秒，完整保留文件访问异常，便于用户导出诊断。
  void _showError(String message) {
    _errorTimer?.cancel();
    setState(() => _error = message);
    _errorTimer = Timer(const Duration(seconds: 12), () {
      if (mounted) setState(() => _error = null);
    });
  }

  void _setDownloading(bool value) => setState(() {
    _downloading = value;
    if (value) _error = null;
  });

  bool _hasPodcast(AudioItem item) =>
      item.podcastTranscriptUrl != null && item.podcastTranscriptFormat != null;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final item =
        ref
            .watch(audioLibraryProvider)
            .audioItems
            .where((i) => i.id == widget.audioItem.id)
            .firstOrNull ??
        widget.audioItem;
    final task = ref.watch(localTranscriptionTaskManagerProvider)[item.id];
    final active =
        task is LocalTranscriptionDecoding ||
        task is LocalTranscriptionTranscribing;
    ref.listen(
      localTranscriptionTaskManagerProvider.select((m) => m[item.id]),
      (_, next) {
        if (next is LocalTranscriptionCompleted) {
          Future.delayed(const Duration(milliseconds: 800), () {
            if (!mounted || !context.mounted) return;
            ref
                .read(localTranscriptionTaskManagerProvider.notifier)
                .clearState(item.id);
            Navigator.pop(context);
          });
        }
      },
    );
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _header(item, active, l10n),
              if (_error case final error?) _notice(error, Icons.error_outline),
              const SizedBox(height: 16),
              if (active || task is LocalTranscriptionCompleted)
                _progress(task, l10n)
              else ...[
                if (task is LocalTranscriptionFailed)
                  _notice(l10n.transcriptionFailed, Icons.error_outline),
                if (task is LocalTranscriptionConflict)
                  _notice(l10n.transcriptionConflict, Icons.sync_problem),
                if (task is LocalTranscriptionEmptyResult)
                  _notice(
                    '${l10n.transcriptionEmptyResult}\n${l10n.transcriptionEmptyResultHint}',
                    Icons.hearing_disabled,
                  ),
                _options(item, l10n),
                const SizedBox(height: 16),
                _action(item, l10n),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(AudioItem item, bool active, AppLocalizations l10n) => Row(
    children: [
      Expanded(
        child: Text(
          l10n.manageSubtitles,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
      if (active)
        TextButton(
          onPressed: () => ref
              .read(localTranscriptionTaskManagerProvider.notifier)
              .cancelTranscription(item.id),
          child: Text(l10n.cancel),
        ),
      if (item.hasTranscript && !active) ...[
        IconButton(
          tooltip: l10n.editSubtitles,
          icon: const Icon(Icons.edit_note),
          onPressed: () {
            final router = GoRouter.of(context);
            Navigator.pop(context);
            router.push(AppRoutes.subtitleEditor(item.id), extra: item);
          },
        ),
        IconButton(
          tooltip: l10n.deleteSubtitle,
          color: Theme.of(context).colorScheme.error,
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _delete(item),
        ),
      ],
    ],
  );

  Widget _notice(String message, IconData icon) => Semantics(
    liveRegion: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
        ],
      ),
    ),
  );

  Widget _options(AudioItem item, AppLocalizations l10n) => Column(
    children: [
      if (_hasPodcast(item))
        _option(
          _SubtitleAction.podcastDownload,
          l10n.downloadPodcastSubtitle,
          Icons.closed_caption_outlined,
          l10n.downloadPodcastSubtitleSubtitle,
        ),
      _option(
        _SubtitleAction.transcription,
        l10n.offlineTranscription,
        Icons.offline_bolt_outlined,
        l10n.offlineTranscriptionSubtitle,
      ),
      if (_selectedAction == _SubtitleAction.transcription) ...[
        if (item.transcriptLanguage == 'auto')
          _notice(l10n.legacyAutoTranscript, Icons.info_outline)
        else
          const TranscriptionOptions(),
      ],
      _option(
        _SubtitleAction.localUpload,
        l10n.localUpload,
        Icons.folder_open_outlined,
      ),
    ],
  );

  Widget _option(
    _SubtitleAction action,
    String title,
    IconData icon, [
    String? subtitle,
  ]) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    selected: action == _selectedAction,
    trailing: Icon(
      action == _selectedAction
          ? Icons.radio_button_checked
          : Icons.radio_button_unchecked,
    ),
    onTap: _downloading ? null : () => setState(() => _selectedAction = action),
  );

  Widget _action(AudioItem item, AppLocalizations l10n) {
    final disabled =
        _downloading ||
        (_selectedAction == _SubtitleAction.transcription &&
            item.transcriptLanguage == 'auto');
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: disabled ? null : () => _runAction(item),
        child: _downloading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(switch (_selectedAction) {
                _SubtitleAction.podcastDownload => l10n.downloadSubtitle,
                _SubtitleAction.localUpload => l10n.uploadTranscript,
                _SubtitleAction.transcription => l10n.startTranscription,
              }),
      ),
    );
  }

  Widget _progress(LocalTranscriptionState? task, AppLocalizations l10n) {
    final progress = task is LocalTranscriptionTranscribing
        ? task.progress
        : null;
    final completed = task is LocalTranscriptionCompleted;
    return Column(
      children: [
        _notice(
          completed
              ? l10n.transcriptionComplete
              : task is LocalTranscriptionDecoding
              ? l10n.localTranscriptionDecoding
              : l10n.transcriptionProcessing,
          completed ? Icons.check_circle_outline : Icons.graphic_eq,
        ),
        if (!completed) ...[
          LinearProgressIndicator(value: progress),
          if (progress != null)
            Text(
              l10n.localTranscriptionProgressPercent(
                (progress.clamp(0, 1) * 100).round(),
              ),
            ),
          _notice(l10n.localTranscriptionForegroundHint, Icons.info_outline),
        ],
      ],
    );
  }

  /// 只调用本机任务；模型下载、覆盖确认与历史字幕保护均在请求前完成。
  Future<void> _runAction(AudioItem item) async {
    if (_selectedAction == _SubtitleAction.podcastDownload) {
      return _downloadPodcast(item);
    }
    if (_selectedAction == _SubtitleAction.localUpload) return _upload(item);
    if (item.transcriptLanguage == 'auto') return;
    if (item.contentStatus case final status?
        when status != AudioContentStatus.ok) {
      if (!await _confirmContent(item, status) || !mounted) return;
    }
    if (item.hasTranscript && (!await _confirmOverwrite() || !mounted)) return;
    final model = ref.read(localTranscriptionModelProvider);
    if (!await ensureAsrModelReadyForTranscription(
          context,
          ref,
          model: model,
        ) ||
        !mounted) {
      return;
    }
    ref
        .read(localTranscriptionTaskManagerProvider.notifier)
        .startLocalTranscription(
          item,
          model: model,
          autoMergeShortSentences: ref.read(transcriptionMergeEnabledProvider),
        );
  }
}
