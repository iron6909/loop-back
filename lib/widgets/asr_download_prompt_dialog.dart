/// 录音与本地转录入口前置弹窗。
///
/// ASR 模型的下载确认、进度、失败和取消状态与 TTS 下载弹窗保持同一交互：
/// 用户显式开始下载，完成后关闭弹窗，原始录音或转录动作不自动恢复。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/enums.dart';
import '../l10n/app_localizations.dart';
import '../providers/asr_model_installation_provider.dart';
import '../providers/learning_settings_provider.dart';
import '../providers/offline_asr_settings_provider.dart';
import '../services/asr/asr_model_manager.dart';
import '../services/asr/offline_asr_engine.dart';
import '../utils/download_failure_message.dart';
import '../utils/file_size.dart';

/// 判断某个学习子阶段是否会进入依赖本地 ASR 的录音流程。
bool requiresAsrBeforeEnteringSubStage(
  SubStageType subStage, {
  bool listenAndRepeatRatingEnabled = true,
  bool retellRatingEnabled = true,
}) {
  return switch (subStage) {
    SubStageType.listenAndRepeat => listenAndRepeatRatingEnabled,
    SubStageType.reviewDifficultPractice => listenAndRepeatRatingEnabled,
    SubStageType.retell => retellRatingEnabled,
    SubStageType.reviewRetellParagraph => retellRatingEnabled,
    SubStageType.reviewRetellSummary => retellRatingEnabled,
    _ => false,
  };
}

/// 在进入语音练习前检查本地 ASR 是否已就绪。
///
/// 返回 `true` 时允许继续原本的进入动作；用户关闭、下载中、下载失败或完成
/// 下载后均返回 `false`，要求用户再次明确触发录音。
Future<bool> ensureAsrReadyBeforeSpeechPractice(
  BuildContext context,
  WidgetRef ref,
) async {
  await ref
      .read(asrModelInstallationGateProvider)
      .ensureInstallationStatesLoaded();
  if (!context.mounted) return false;
  final state = ref.read(offlineAsrSettingsProvider);

  // 非 offline 后端不依赖本地 Whisper 模型。
  if (state.backend != AsrBackend.offline) return true;
  if (state.downloadStatus == AsrModelDownloadStatus.downloaded) {
    unawaited(_ensureEngineLoaded(ref));
    return true;
  }

  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _AsrModelDownloadDialog(
      modelId: state.selectedModel.id,
      intro: AppLocalizations.of(context)!.speechRecognitionRequiredMessage,
      startDownload: () =>
          ref.read(offlineAsrSettingsProvider.notifier).enable(),
    ),
  );
  return false;
}

/// 在发起本地转录前检查指定 Whisper 档位模型。
///
/// 此检查不读取评分后端，也不会修改评分选中的模型。与 TTS 门控一致，模型
/// 下载完成后本次转录不会自动恢复。
Future<bool> ensureAsrModelReadyForTranscription(
  BuildContext context,
  WidgetRef ref, {
  required AsrModelInfo model,
}) async {
  await ref
      .read(asrModelInstallationGateProvider)
      .ensureInstallationStatesLoaded();
  if (!context.mounted) return false;
  if (ref
          .read(offlineAsrSettingsProvider)
          .modelStateOf(model.id)
          .downloadStatus ==
      AsrModelDownloadStatus.downloaded) {
    return true;
  }

  final l10n = AppLocalizations.of(context)!;
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _AsrModelDownloadDialog(
      modelId: model.id,
      intro: l10n.localTranscriptionModelRequiredMessage(model.displayName),
      startDownload: () =>
          ref.read(offlineAsrSettingsProvider.notifier).retryDownload(model.id),
    ),
  );
  return false;
}

/// 仅在目标子阶段依赖本地 ASR 时执行前置检查。
Future<bool> ensureAsrReadyForSubStage(
  BuildContext context,
  WidgetRef ref,
  SubStageType subStage,
) {
  final settings = ref.read(learningSettingsProvider);
  if (!requiresAsrBeforeEnteringSubStage(
    subStage,
    listenAndRepeatRatingEnabled: settings.listenAndRepeatRatingEnabled,
    retellRatingEnabled: settings.retellRatingEnabled,
  )) {
    return Future.value(true);
  }
  return ensureAsrReadyBeforeSpeechPractice(context, ref);
}

/// 后台加载引擎，不阻塞已安装模型进入录音流程。
Future<void> _ensureEngineLoaded(WidgetRef ref) async {
  final state = ref.read(offlineAsrSettingsProvider);
  if (state.backend == AsrBackend.offline &&
      state.downloadStatus == AsrModelDownloadStatus.downloaded &&
      !state.engineReady) {
    await ref.read(offlineAsrSettingsProvider.notifier).loadEngine();
  }
}

/// ASR 的统一下载弹窗，结构和状态转换与 TTS 下载弹窗对齐。
class _AsrModelDownloadDialog extends ConsumerWidget {
  const _AsrModelDownloadDialog({
    required this.modelId,
    required this.intro,
    required this.startDownload,
  });

  final String modelId;
  final String intro;
  final Future<void> Function() startDownload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final model = ref.watch(
      offlineAsrSettingsProvider.select((state) => state.modelStateOf(modelId)),
    );
    final size = formatBytes(
      asrPublicResourceCatalog[modelId]?.estimatedDownloadBytes ?? 0,
    );
    final status = model.downloadStatus;
    final notDownloaded = status == AsrModelDownloadStatus.notDownloaded;
    final downloading = status == AsrModelDownloadStatus.downloading;
    final failed = status == AsrModelDownloadStatus.failed;

    if (status == AsrModelDownloadStatus.downloaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).pop();
      });
    }

    final title = switch (status) {
      AsrModelDownloadStatus.notDownloaded =>
        l10n.asrModelDownloadRequiredTitle,
      AsrModelDownloadStatus.downloading => l10n.asrModelDownloadingTitle,
      AsrModelDownloadStatus.failed => l10n.asrModelDownloadFailedTitle,
      AsrModelDownloadStatus.downloaded => l10n.asrModelDownloadRequiredTitle,
    };
    final progress = '${(model.downloadProgress * 100).toStringAsFixed(0)}%';

    return AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (notDownloaded)
            _DownloadMessage(
              children: [
                Text(intro),
                Text(l10n.asrModelDownloadEstimate(size)),
                Text(l10n.asrModelDownloadSettingsHint),
              ],
            ),
          if (downloading) ...[
            _DownloadMessage(
              children: [Text(l10n.asrModelDownloadingMessage(size))],
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: model.downloadProgress),
            const SizedBox(height: 8),
            Text(
              l10n.asrModelDownloadProgress(progress),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (failed) ...[
            const SizedBox(height: 8),
            _DownloadMessage(
              children: [
                Text(l10n.asrModelDownloadFailedMessage(size)),
                Text(l10n.asrModelDownloadSettingsHint),
              ],
            ),
            if (model.downloadError != null) ...[
              const SizedBox(height: 8),
              Text(
                downloadFailureMessage(l10n, model.downloadError),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ],
      ),
      actions: downloading
          ? [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  // 先关闭弹窗，避免状态回到未下载时短暂显示下载按钮。
                  unawaited(
                    ref
                        .read(offlineAsrSettingsProvider.notifier)
                        .cancelDownload(modelId),
                  );
                },
                child: Text(l10n.downloadCancel),
              ),
            ]
          : failed
          ? [
              FilledButton(
                onPressed: () => ref
                    .read(offlineAsrSettingsProvider.notifier)
                    .retryDownload(modelId),
                child: Text(l10n.retryDownload),
              ),
            ]
          : notDownloaded
          ? [
              FilledButton(
                onPressed: () => unawaited(startDownload()),
                child: Text(l10n.asrDownloadModel),
              ),
            ]
          : const [],
    );
  }
}

/// 将下载说明拆成有间距的段落，与 TTS 下载弹窗的排版保持一致。
class _DownloadMessage extends StatelessWidget {
  const _DownloadMessage({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0) const SizedBox(height: 10),
          DefaultTextStyle.merge(style: style, child: children[index]),
        ],
      ],
    );
  }
}
