/// 复述评估弹窗：本机转写与供应商请求的加载、结果和失败状态。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../features/subscription/models/ai_quota_rejection.dart';
import '../../providers/retell_review_evaluation_provider.dart';
import '../../services/audio_preview_controller.dart';
import '../../services/provider/provider_error_text.dart';
import '../../theme/app_theme.dart';
import 'retell_review_report.dart';

/// 与页面级提示共用错误分类；旧 quotaReason 参数只供现有调用兼容。
String retellReviewErrorMessage(AppLocalizations l10n, String? errorCode, {
  AiQuotaRejectionReason quotaReason = AiQuotaRejectionReason.exhausted,
}) => providerErrorCodeText(errorCode, l10n.localeName.startsWith('zh'));

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
    return SafeArea(top: false, child: SizedBox(
      key: const ValueKey('retell-review-sheet'),
      height: MediaQuery.sizeOf(context).height * .8,
      child: Padding(padding: const EdgeInsets.all(AppSpacing.m), child: Column(
        children: [
          Row(children: [Expanded(child: Text(l10n.retellAiReviewTitle,
            style: Theme.of(context).textTheme.titleLarge)),
            IconButton(tooltip: MaterialLocalizations.of(context).closeButtonTooltip, onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded))]),
          if (pending) const LinearProgressIndicator(),
          Expanded(child: state.phase == RetellReviewEvaluationPhase.failed
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error_outline),
                Text(retellReviewErrorMessage(l10n, state.errorCode)),
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
