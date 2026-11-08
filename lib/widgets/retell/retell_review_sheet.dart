/// 复述评估弹窗：转写与供应商请求的加载、结果和失败状态。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../features/subscription/models/ai_quota_rejection.dart';
import '../../providers/retell_review_evaluation_provider.dart';
import '../../services/audio_preview_controller.dart';
import '../../services/provider/provider_error_text.dart';
import '../../services/speech/practice_chunk_transcriber.dart';
import '../../services/speech/speech_error_text.dart';
import '../../theme/app_theme.dart';
import 'retell_review_report.dart';

/// 与页面级提示共用错误分类；旧 quotaReason 参数只供现有调用兼容。
String retellReviewErrorMessage(AppLocalizations l10n, String? errorCode, {
  AiQuotaRejectionReason quotaReason = AiQuotaRejectionReason.exhausted,
}) => providerErrorCodeText(errorCode, l10n.localeName.startsWith('zh'));

/// 复述评估的失败文案。
///
/// 转写阶段失败（语音配置、录音边界或转写本身）用在线语音的分类说明，文字 AI
/// 的失败仍用供应商分类：两类错误分开呈现，不把技术失败当成表达错误。
String retellReviewErrorText(
  BuildContext context,
  RetellReviewEvaluationState state,
) {
  final speechError = state.speechError;
  if (speechError != null) return speechErrorText(context, speechError);
  return retellReviewErrorMessage(
    AppLocalizations.of(context)!,
    state.errorCode,
  );
}

Future<void> showRetellReviewSheet(BuildContext context, {
  required String recordingPath, required AudioPreviewController preview,
  required Future<void> Function() onBeforePlayback,
  required Future<void> Function() onRetry,
}) async {
  try {
    await showModalBottomSheet<void>(context: context, isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RetellReviewSheet(recordingPath: recordingPath,
        preview: preview, onBeforePlayback: onBeforePlayback, onRetry: onRetry));
  } finally { await preview.stop(); }
}

class _RetellReviewSheet extends ConsumerWidget {
  const _RetellReviewSheet({required this.recordingPath, required this.preview,
    required this.onBeforePlayback, required this.onRetry});
  final String recordingPath;
  final AudioPreviewController preview;
  final Future<void> Function() onBeforePlayback;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(retellReviewEvaluationProvider);
    final l10n = AppLocalizations.of(context)!;
    final pending = state.phase == RetellReviewEvaluationPhase.loading ||
      state.phase == RetellReviewEvaluationPhase.streaming;
    final evaluation = state.evaluation;
    final speechError = state.speechError;
    // 分块转写失败停在具体块上：向用户说清重试会不会重复计费。
    final chunkFailure = speechError is PracticeChunkFailure ? speechError : null;
    return SafeArea(top: false, child: SizedBox(
      key: const ValueKey('retell-review-sheet'),
      height: MediaQuery.sizeOf(context).height * .8,
      child: Padding(padding: const EdgeInsets.all(AppSpacing.m), child: Column(
        children: [
          Row(children: [Expanded(child: Text(l10n.retellAiReviewTitle,
            style: Theme.of(context).textTheme.titleLarge)),
            IconButton(tooltip: MaterialLocalizations.of(context).closeButtonTooltip, onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded))]),
          // 在线转写只在供应商真报了费用时给数字，缺失就写未知。
          if (state.onlineSpeech case final onlineSpeech?)
            Align(alignment: Alignment.centerLeft, child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                speechCostText(l10n.localeName.startsWith('zh'),
                  onlineSpeech.reportedCost),
                style: Theme.of(context).textTheme.bodySmall))),
          if (pending) const LinearProgressIndicator(),
          Expanded(child: state.phase == RetellReviewEvaluationPhase.failed
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error_outline),
                Text(retellReviewErrorText(context, state)),
                if (chunkFailure != null && chunkFailure.mayHaveBeenCharged)
                  Padding(padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(l10n.shadowingOnlineChargeWarning,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error))),
                FilledButton.tonalIcon(onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded), label: Text(l10n.retellAiReviewRetry)),
              ]))
            : evaluation == null ? const Center(child: CircularProgressIndicator())
            : RetellReviewReport(evaluation: evaluation, isStreaming: pending,
                recordingPath: recordingPath, preview: preview,
                onBeforePlayback: onBeforePlayback)),
        ],
      )),
    ));
  }
}
