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
import '../models/recognition_selection.dart';
import '../providers/audio_library_provider.dart';
import '../providers/local_transcription_task_provider.dart';
import '../providers/online_subtitle_task_provider.dart';
import '../providers/recognition_settings_provider.dart';
import '../providers/speech_capability_provider.dart';
import '../providers/speech_configuration_provider.dart';
import '../services/speech/speech_config.dart';
import '../services/speech/speech_error_text.dart';
import '../services/speech/speech_transcription_client.dart';
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
    final onlineTask = ref.read(
      onlineSubtitleTaskManagerProvider,
    )[widget.audioItem.id];
    // 可续试的失败要留到用户主动重试；只有不可续试的旧失败才随弹窗重开清掉。
    if (onlineTask is OnlineSubtitleFailed && !onlineTask.retryable ||
        onlineTask is OnlineSubtitleConflict) {
      Future(() {
        if (mounted) {
          ref
              .read(onlineSubtitleTaskManagerProvider.notifier)
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
    final onlineTask = ref.watch(onlineSubtitleTaskManagerProvider)[item.id];
    final localActive =
        task is LocalTranscriptionDecoding ||
        task is LocalTranscriptionTranscribing;
    final onlineActive = onlineTask is OnlineSubtitleWorking;
    final active = localActive || onlineActive;
    ref.listen(
      onlineSubtitleTaskManagerProvider.select((m) => m[item.id]),
      (_, next) {
        if (next is OnlineSubtitleCompleted) {
          Future.delayed(const Duration(milliseconds: 800), () {
            if (!mounted || !context.mounted) return;
            ref
                .read(onlineSubtitleTaskManagerProvider.notifier)
                .clearState(item.id);
            Navigator.pop(context);
          });
        }
      },
    );
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
              if (item.hasTranscript && !active) _timingSource(item, l10n),
              if (active ||
                  task is LocalTranscriptionCompleted ||
                  onlineTask is OnlineSubtitleCompleted)
                _progress(task, onlineTask, l10n)
              else ...[
                if (task is LocalTranscriptionFailed)
                  _notice(l10n.transcriptionFailed, Icons.error_outline),
                if (onlineTask case OnlineSubtitleFailed(:final reason, :final speechError))
                  _notice(
                    _onlineFailureText(l10n, reason, speechError),
                    Icons.error_outline,
                  ),
                if (onlineTask case OnlineSubtitleFailed(
                  retryable: true,
                  mayHaveBeenCharged: true,
                ))
                  _notice(l10n.onlineSubtitleRetryCostWarning, Icons.payments_outlined),
                if (onlineTask case OnlineSubtitleFailed(
                  retryable: true,
                  :final completedChunks,
                  :final totalChunks,
                  :final failedChunk,
                ))
                  _notice(
                    failedChunk == null
                        ? l10n.onlineSubtitleChunkProgress(
                            completedChunks,
                            totalChunks,
                          )
                        : l10n.onlineSubtitleFailedChunk(
                            failedChunk,
                            totalChunks,
                          ),
                    Icons.list_alt,
                  ),
                if (task is LocalTranscriptionConflict ||
                    onlineTask is OnlineSubtitleConflict)
                  _notice(l10n.transcriptionConflict, Icons.sync_problem),
                if (onlineTask is OnlineSubtitleNoSpeech)
                  _notice(l10n.onlineSubtitleNoSpeech, Icons.hearing_disabled),
                if (task is LocalTranscriptionEmptyResult)
                  _notice(
                    '${l10n.transcriptionEmptyResult}\n${l10n.transcriptionEmptyResultHint}',
                    Icons.hearing_disabled,
                  ),
                _options(item, l10n),
                const SizedBox(height: 16),
                _action(item, l10n, onlineTask),
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
          onPressed: () {
            ref
                .read(localTranscriptionTaskManagerProvider.notifier)
                .cancelTranscription(item.id);
            ref
                .read(onlineSubtitleTaskManagerProvider.notifier)
                .cancelTranscription(item.id);
          },
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
        else ...[
          const TranscriptionOptions(),
          _subtitleModeNotice(l10n),
        ],
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

  Widget _action(
    AudioItem item,
    AppLocalizations l10n,
    OnlineSubtitleTaskState? onlineTask,
  ) {
    final disabled =
        _downloading ||
        (_selectedAction == _SubtitleAction.transcription &&
            item.transcriptLanguage == 'auto');
    // 可续试的失败：主按钮只重发失败与未完成块，不重新上传已成功部分。
    final resumable =
        _selectedAction == _SubtitleAction.transcription &&
        onlineTask is OnlineSubtitleFailed &&
        onlineTask.retryable;
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
            : Text(
                resumable
                    ? l10n.onlineSubtitleRetryUnfinished
                    : switch (_selectedAction) {
                        _SubtitleAction.podcastDownload => l10n.downloadSubtitle,
                        _SubtitleAction.localUpload => l10n.uploadTranscript,
                        _SubtitleAction.transcription => l10n.startTranscription,
                      },
              ),
      ),
    );
  }

  /// 进度区：本机任务显示真实进度，在线单块请求只能显示服务与模型。
  Widget _progress(
    LocalTranscriptionState? task,
    OnlineSubtitleTaskState? onlineTask,
    AppLocalizations l10n,
  ) {
    if (onlineTask is OnlineSubtitleWorking) {
      return Column(
        children: [
          _notice(
            l10n.onlineSubtitleService(
              _serviceLabel(l10n, onlineTask.service),
              onlineTask.modelId,
            ),
            Icons.cloud_upload_outlined,
          ),
          _notice(
            l10n.onlineSubtitleChunkProgress(
              onlineTask.completedChunks,
              onlineTask.totalChunks,
            ),
            Icons.list_alt,
          ),
          _notice(l10n.transcriptionProcessing, Icons.graphic_eq),
          LinearProgressIndicator(
            value: onlineTask.totalChunks == 0
                ? null
                : onlineTask.completedChunks / onlineTask.totalChunks,
          ),
        ],
      );
    }
    if (onlineTask is OnlineSubtitleCompleted) {
      return Column(
        children: [
          _notice(l10n.transcriptionComplete, Icons.check_circle_outline),
          _notice(
            l10n.onlineSubtitleService(
              _serviceLabel(l10n, _subtitleService),
              onlineTask.modelId,
            ),
            Icons.cloud_outlined,
          ),
          _notice(
            onlineTask.reportedCost == null
                ? l10n.onlineSubtitleCostUnknown
                : l10n.onlineSubtitleCost(onlineTask.reportedCost.toString()),
            Icons.payments_outlined,
          ),
          _notice(
            l10n.wordTimingSourceLabel(
              _wordTimingLabel(l10n, onlineTask.wordTimingSource),
            ),
            Icons.timeline,
          ),
        ],
      );
    }
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

  /// 字幕用途当前识别方式说明。
  ///
  /// 本机时也明说一句「当前用本机、去哪儿换成在线」，否则弹窗只列本机模型，
  /// 用户会以为应用根本不支持在线识别。
  Widget _subtitleModeNotice(AppLocalizations l10n) {
    final selection = ref
        .read(recognitionSettingsProvider)
        .forPurpose(RecognitionPurpose.subtitle);
    if (selection.mode != RecognitionMode.online) {
      return _notice(l10n.subtitleModeLocalHint, Icons.memory);
    }
    if (!ref.watch(onlineSubtitleAvailableProvider)) {
      return _notice(l10n.onlineSubtitleNotVerified, Icons.error_outline);
    }
    final config = ref.read(speechConfigurationProvider).valueOrNull?.config;
    final modelId = config?.onlineModelFor(RecognitionPurpose.subtitle) ?? '';
    return _notice(
      l10n.onlineSubtitleService(_serviceLabel(l10n, _subtitleService), modelId),
      Icons.cloud_outlined,
    );
  }

  /// 当前字幕的词时间戳来源提示；只展示实际标记，不因来源是在线就宣称逐词精确。
  Widget _timingSource(AudioItem item, AppLocalizations l10n) => _notice(
    l10n.wordTimingSourceLabel(
      _wordTimingLabel(l10n, item.transcriptWordTimingSource),
    ),
    Icons.timeline,
  );

  /// 字幕在线方式当前选中的服务名；未配置时返回空字符串。
  String get _subtitleService =>
      ref.read(speechConfigurationProvider).valueOrNull?.config?.kind.name ?? '';

  /// 服务显示名：预设名与自定义服务各一个说法，不暴露地址与凭据。
  String _serviceLabel(AppLocalizations l10n, String service) =>
      service == SpeechProviderKind.openrouter.name
      ? l10n.providerKindOpenRouter
      : l10n.providerKindCustom;

  /// 词时间戳来源文案；null 表示历史数据缺少标记。
  String _wordTimingLabel(
    AppLocalizations l10n,
    TranscriptWordTimingSource? source,
  ) => switch (source) {
    TranscriptWordTimingSource.model => l10n.wordTimingSourceModel,
    TranscriptWordTimingSource.estimated => l10n.wordTimingSourceEstimated,
    TranscriptWordTimingSource.mixed => l10n.wordTimingSourceMixed,
    null => l10n.wordTimingSourceUnknown,
  };

  /// 在线失败文案：供应商错误用既有分类文案，本地原因各自说明下一步。
  String _onlineFailureText(
    AppLocalizations l10n,
    OnlineSubtitleFailureReason reason,
    SpeechTranscriptionException? speechError,
  ) {
    if (speechError != null) return speechErrorText(context, speechError);
    return switch (reason) {
      OnlineSubtitleFailureReason.notConfigured =>
        l10n.onlineSubtitleNotConfigured,
      OnlineSubtitleFailureReason.notVerified => l10n.onlineSubtitleNotVerified,
      OnlineSubtitleFailureReason.decodeFailed =>
        l10n.onlineSubtitleDecodeFailed,
      OnlineSubtitleFailureReason.invalidResult =>
        l10n.onlineSubtitleInvalidResult,
      OnlineSubtitleFailureReason.configChanged =>
        l10n.onlineSubtitleConfigChanged,
      OnlineSubtitleFailureReason.unknown => l10n.transcriptionFailed,
    };
  }

  /// 路由到在线或本机任务；覆盖确认与历史字幕保护均在请求前完成。
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
    // 字幕用途的选择与设置页共用同一份状态。
    final selection = ref
        .read(recognitionSettingsProvider)
        .forPurpose(RecognitionPurpose.subtitle);
    if (selection.mode == RecognitionMode.online) {
      // 在线不经过本地模型/VAD 安装门控；能力与范围校验在任务里复核。
      ref
          .read(onlineSubtitleTaskManagerProvider.notifier)
          .startOnlineTranscription(
            item,
            autoMergeShortSentences: ref.read(transcriptionMergeEnabledProvider),
          );
      return;
    }
    final model = ref.read(
      recognitionLocalModelProvider(RecognitionPurpose.subtitle),
    );
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
