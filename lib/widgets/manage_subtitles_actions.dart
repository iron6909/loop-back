part of 'manage_subtitles_sheet.dart';

/// 字幕文件操作：确认后才写库，下载和解析失败均保留已有内容。
extension _SubtitleActions on _ManageSubtitlesSheetState {
  Future<bool> _confirmOverwrite() => _confirm(
    AppLocalizations.of(context)!.overwriteExistingSubtitle,
    Text(AppLocalizations.of(context)!.overwriteExistingSubtitleMessage),
    AppLocalizations.of(context)!.overwrite,
  );

  Future<bool> _confirm(String title, Widget content, String action) async {
    final l10n = AppLocalizations.of(context)!;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: content,
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(action),
              ),
            ],
          ),
        ) ==
        true;
  }

  Future<void> _downloadPodcast(AudioItem item) async {
    final url = item.podcastTranscriptUrl;
    final format = item.podcastTranscriptFormat;
    if (url == null || format == null || _downloading) return;
    if (item.hasTranscript && (!await _confirmOverwrite() || !mounted)) return;
    final l10n = AppLocalizations.of(context)!;
    _setDownloading(true);
    try {
      final text = await ref
          .read(podcastTranscriptDownloaderProvider)
          .download(url, format: format);
      if (!mounted) return;
      final sentences = await parseSupportedSubtitle(text, ext: format);
      if (sentences.isEmpty) {
        throw const SubtitleParseException(SubtitleParseErrorKind.empty);
      }
      if (!mounted) return;
      await importLocalSubtitle(ref, item, text: text, ext: format);
      ref.invalidate(audioSentencesProvider(item.id));
      if (mounted) Navigator.pop(context);
    } on SubtitleParseException catch (error) {
      if (mounted) _showError(subtitleParseErrorMessage(l10n, error));
    } catch (error, stack) {
      AppLogger.log('SubtitleDownload', '$error\n$stack');
      if (mounted) _showError('${l10n.downloadSubtitleFailed}: $error');
    } finally {
      if (mounted) _setDownloading(false);
    }
  }

  Future<void> _upload(AudioItem item) async {
    if (item.hasTranscript && (!await _confirmOverwrite() || !mounted)) return;
    final l10n = AppLocalizations.of(context)!;
    try {
      final picker =
          widget.transcriptContentPicker ?? pickTranscriptContentWithMetadata;
      final transcript = await picker();
      if (transcript == null || !mounted) return;
      AppLogger.log(
        'SubtitleUpload',
        'picked transcript audioId=${item.id} charset=${transcript.charset} ext=${transcript.ext} chars=${transcript.text.length}',
      );
      await importLocalSubtitle(
        ref,
        item,
        text: transcript.text,
        ext: transcript.ext,
      );
      if (!mounted) return;
      ref
          .read(usageTrackerProvider)
          .record(
            UsageEvent.subtitleUploaded,
            analyticsParams: {
              EventParams.audioId: item.id,
              EventParams.audioName: item.name,
            },
          );
      Navigator.pop(context);
    } on SubtitleParseException catch (error) {
      if (mounted) _showError(subtitleParseErrorMessage(l10n, error));
    } catch (error, stack) {
      AppLogger.log(
        'SubtitleUpload',
        'failed local upload audioId=${item.id} errorType=${error.runtimeType} error=$error\n$stack',
      );
      if (mounted) _showError('${l10n.pickTranscriptFileFailed}: $error');
    }
  }

  Future<bool> _confirmContent(
    AudioItem item,
    AudioContentStatus status,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final fullPath = await item.getFullAudioPath();
    var size = l10n.transcriptionAudioUnknown;
    try {
      if (fullPath != null && await File(fullPath).exists()) {
        size = formatBytes(await File(fullPath).length());
      }
    } on FileSystemException {
      // 诊断信息读取失败不改变确认与转录的权限。
    }
    final seconds = item.totalDuration > 0
        ? item.totalDuration
        : fullPath == null
        ? 0
        : await getMediaDurationSeconds(fullPath);
    if (!mounted) return false;
    return _confirm(
      status == AudioContentStatus.damaged
          ? l10n.transcriptionDamagedConfirmTitle
          : l10n.transcriptionSilentConfirmTitle,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            status == AudioContentStatus.damaged
                ? l10n.transcriptionDamagedConfirmMessage
                : l10n.transcriptionSilentConfirmMessage,
          ),
          Text(l10n.transcriptionAudioFileSize(size)),
          Text(
            l10n.transcriptionAudioDuration(
              seconds > 0
                  ? SubtitleParser.formatDuration(Duration(seconds: seconds))
                  : l10n.transcriptionAudioUnknown,
            ),
          ),
        ],
      ),
      l10n.transcriptionSilentConfirmProceed,
    );
  }

  /// 删除字幕时同时清理依赖句子索引的收藏与进度；原始音频不变。
  Future<void> _delete(AudioItem item) async {
    final l10n = AppLocalizations.of(context)!;
    if (!await _confirm(
          l10n.deleteSubtitleConfirm,
          Text(l10n.deleteSubtitleWarning),
          l10n.delete,
        ) ||
        !mounted) {
      return;
    }
    if (await item.getFullTranscriptPath() case final path?) {
      try {
        if (await File(path).exists()) await File(path).delete();
      } on FileSystemException catch (error) {
        AppLogger.log('SubtitleDelete', 'legacy file cleanup failed: $error');
      }
    }
    final dao = ref.read(audioItemDaoProvider);
    await dao.updateTranscriptSrt(item.id, null);
    await dao.updateWordTimestamps(item.id, null);
    ref.invalidate(audioSentencesProvider(item.id));
    final updated = item.copyWith(
      transcriptPath: null,
      transcriptSource: null,
      transcriptLanguage: null,
      sentenceCount: 0,
      wordCount: 0,
    );
    ref.read(audioLibraryProvider.notifier).updateAudioItem(updated);
    await ref
        .read(favoriteSentenceLifecycleProvider)
        .removeAllForAudio(item.id);
    await ref
        .read(learningProgressNotifierProvider.notifier)
        .resetProgress(item.id);
    if (ref.read(listeningPracticeProvider).currentAudioItem?.id == item.id) {
      ref
          .read(listeningPracticeProvider.notifier)
          .loadAudio(updated, forceTranscriptReload: true);
    }
  }
}
