/// 练习页面共享的中间操作区
///
/// 固定槽位布局，避免状态切换时布局跳动：
/// 1. 状态文字槽位（居中，20px）
/// 2. 间距（8px）
/// 3. 按钮行（56px）：badge(左) + 中间内容(居中) + 快进(右)
///    与 PlaybackControls 同 Row 结构，badge 对齐 prev，快进对齐 next。
/// 4. 底部间距（16px）
///
/// 中间内容、状态文字、评分 badge 均由内部根据状态自动构建。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/speech_practice_models.dart';
import '../../services/audio_preview_controller.dart';
import '../../services/speech/shadowing_online_transcriber.dart';
import '../../services/speech/speech_error_text.dart';
import '../../theme/app_theme.dart';
import 'playback_controls.dart' show PlaybackControls;
import 'processing_indicator.dart';
import 'recording_button.dart' show RecordingButton, RecordingButtonMode;
import 'speech_rating_badge.dart';
import 'status_label.dart';
import 'tappable_wrapper.dart';

/// 正常状态文字槽位高度
const double _kStatusSlotHeight = 20;

/// 槽位间距
const double _kSlotGap = 8;

/// 按钮行高度
const double _kButtonRowHeight = 56;

/// 按钮行到底部 footer 的间距
const double _kBottomGap = 16;

/// 固定总高度：状态文字(20) + 间距(8) + 按钮行(56) + 底部间距(16) = 100
const double kTurnAreaHeight =
    _kStatusSlotHeight + _kSlotGap + _kButtonRowHeight + _kBottomGap;

/// 错误文案允许双行，避免英文提示在窄屏被截断。
const double _kErrorStatusSlotHeight = 40;

/// 错误模式总高度：错误文案(40) + 间距(8) + 按钮行(56) + 底部间距(16) = 120
const double _kErrorTurnAreaHeight =
    _kErrorStatusSlotHeight + _kSlotGap + _kButtonRowHeight + _kBottomGap;

/// 练习页面共享的中间操作区
class RepeatPracticePanel extends StatelessWidget {
  // ========== 数据 ==========

  /// 录音按钮模式（由调用方根据录音状态计算）
  final RecordingButtonMode recordingMode;

  /// 是否处于评估加载中
  final bool isProcessing;

  /// 当前评估结果
  final SpeechPracticeAttempt? currentAttempt;

  /// 在线跟读的转写状态；非在线方式或未开始时为 null。
  final ShadowingOnlineState? onlineStatus;

  /// 本地化
  final AppLocalizations l10n;

  /// 主题
  final ThemeData theme;

  // ========== 状态标志 ==========

  /// 提示文本（如"先听再跟读"，播放中显示）
  final String? hintText;

  /// 是否显示倒计时
  final bool showCountdown;

  /// 是否处于停顿状态（录音/等待/倒计时）
  final bool isInPause;

  // ========== 外部 widget ==========

  /// 倒计时 widget（由调用方通过 Consumer 构建，监听各自的 provider）
  final Widget? countdownWidget;

  // ========== 回调 ==========

  /// 录音按钮点击回调
  final VoidCallback onRecordTap;

  /// 快进回调（非 null 时显示快进按钮）
  final VoidCallback? onFastForward;

  /// 在线分块转写失败后的手动续试；非 null 且仍有未完成块时显示重试入口。
  final VoidCallback? onRetryOnline;

  /// badge 播放录音前的准备回调
  final FutureOr<void> Function()? onBeforePlayback;

  /// badge 播放控制器，用于页面触发与用户点击 badge 相同的回放流程。
  final SpeechRatingBadgeController? ratingBadgeController;

  /// badge 试听控制器工厂，用于与页面其他播放入口共用同一份播放状态。
  final AudioPreviewController Function()? ratingPreviewControllerFactory;

  // ========== 配置 ==========

  /// 评分阈值
  final RatingThresholds thresholds;

  /// 是否显示评级/录音胶囊。
  final bool showRatingBadge;

  /// 是否为当前录音 badge 提供 AI 复述评估入口。
  ///
  /// 默认关闭，跟读等其他复用页面不会显示该入口。
  final bool showAiReviewButton;

  /// AI 评估请求是否正在准备或等待首个流式结果。
  final bool isAiReviewLoading;

  /// 点击 AI 评估入口。
  final VoidCallback? onAiReviewTap;

  const RepeatPracticePanel({
    super.key,
    this.recordingMode = RecordingButtonMode.idle,
    this.isProcessing = false,
    this.currentAttempt,
    this.onlineStatus,
    required this.l10n,
    required this.theme,
    this.hintText,
    required this.showCountdown,
    required this.isInPause,
    this.countdownWidget,
    required this.onRecordTap,
    this.onFastForward,
    this.onRetryOnline,
    this.onBeforePlayback,
    this.ratingBadgeController,
    this.ratingPreviewControllerFactory,
    this.thresholds = RatingThresholds.listenAndRepeat,
    this.showRatingBadge = true,
    this.showAiReviewButton = false,
    this.isAiReviewLoading = false,
    this.onAiReviewTap,
  });

  @override
  Widget build(BuildContext context) {
    // processing 状态：加载动画独占整个区域（自然高度 > 56px，不适合按钮行）
    if (isProcessing) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.l),
        child: SizedBox(
          height: kTurnAreaHeight,
          child: Center(
            child: ProcessingIndicator(text: _processingText(context)),
          ),
        ),
      );
    }

    final statusText = _buildStatusText(context);
    final hasStatus = statusText != null;
    final currentBadgeAttempt = _badgeAttempt;
    final hasBadge = currentBadgeAttempt != null;
    final hasFF = onFastForward != null;
    final hasAiReview = hasBadge && showAiReviewButton && onAiReviewTap != null;
    final hasRightControl = hasAiReview || hasFF;
    final statusSlotHeight = _usesExpandedStatusSlot
        ? _kErrorStatusSlotHeight
        : _kStatusSlotHeight;
    final panelHeight = _usesExpandedStatusSlot
        ? _kErrorTurnAreaHeight
        : kTurnAreaHeight;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.l),
      child: SizedBox(
        height: panelHeight,
        child: Column(
          children: [
            // 状态文字槽位（固定高度，AnimatedOpacity 控制显隐）
            SizedBox(
              height: statusSlotHeight,
              child: Center(
                child: AnimatedOpacity(
                  opacity: hasStatus ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: statusText ?? const SizedBox.shrink(),
                ),
              ),
            ),
            const SizedBox(height: _kSlotGap),
            // 按钮行：badge(左) + 中间内容(居中) + 快进(右)
            // 使用 Stack 让 hintText 可以占满整行宽度，不被左右槽位挤压
            // 固定宽度结构与 PlaybackControls 一致，保证左右槽位对齐 prev/next
            SizedBox(
              height: _kButtonRowHeight,
              child: Stack(
                children: [
                  // 底层：三栏布局（badge + 中间内容 + 快进）
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // 左槽位：badge（与 prev 按钮同宽同位）
                      SizedBox(
                        width: PlaybackControls.controlButtonSize,
                        height: _kButtonRowHeight,
                        child: OverflowBox(
                          maxWidth: 160,
                          minHeight: 0,
                          alignment: Alignment.center,
                          child: AnimatedOpacity(
                            opacity: hasBadge ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 200),
                            child: IgnorePointer(
                              ignoring: !hasBadge,
                              child: currentBadgeAttempt != null
                                  ? SpeechRatingBadge(
                                      l10n: l10n,
                                      attempt: currentBadgeAttempt,
                                      onBeforePlayback:
                                          currentBadgeAttempt.hasRecording
                                          ? onBeforePlayback
                                          : null,
                                      thresholds: thresholds,
                                      controller: ratingBadgeController,
                                      previewControllerFactory:
                                          ratingPreviewControllerFactory,
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 48),
                      // 中间槽位：固定宽度与 PlaybackControls 中心按钮一致
                      SizedBox(
                        width: PlaybackControls.controlButtonSize,
                        height: _kButtonRowHeight,
                        child: Center(
                          child: hintText != null
                              ? const SizedBox.shrink()
                              : _buildCenterContent(),
                        ),
                      ),
                      const SizedBox(width: 48),
                      // 右槽位：复述 AI 评估胶囊与左侧录音 badge 对称；未启用
                      // 时保留既有快进按钮，避免影响跟读等其他练习页面。
                      SizedBox(
                        width: PlaybackControls.controlButtonSize,
                        height: _kButtonRowHeight,
                        child: Center(
                          child: AnimatedOpacity(
                            opacity: hasRightControl ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 200),
                            child: IgnorePointer(
                              ignoring: !hasRightControl,
                              child: hasAiReview
                                  ? OverflowBox(
                                      maxWidth: 160,
                                      minHeight: 0,
                                      alignment: Alignment.center,
                                      child: _buildAiReviewPill(),
                                    )
                                  : hasFF
                                  ? GestureDetector(
                                      onTap: onFastForward,
                                      child: Icon(
                                        Icons.fast_forward_rounded,
                                        size: 32,
                                        color: theme.colorScheme.onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  // 顶层：hintText 占满整行居中显示
                  if (hintText != null) Center(child: _buildCenterContent()),
                ],
              ),
            ),
            // 底部间距（与 footer 之间的间距）
            const SizedBox(height: _kBottomGap),
          ],
        ),
      ),
    );
  }

  /// 构建右侧「AI 评估」胶囊。
  ///
  /// 与左侧 [SpeechRatingBadge] 共用同一套胶囊语言（999 圆角、
  /// h10/v6 内边距、labelMedium 文字、16px 图标、中性表面色 + 细描边），
  /// 只用 primary 色的星芒图标点出 AI 属性，避免抢视觉重心。
  Widget _buildAiReviewPill() {
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark
        ? theme.colorScheme.onSurface.withValues(alpha: 0.8)
        : theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final bgColor = isDark
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.surfaceContainerHigh;
    final borderColor = isDark
        ? theme.colorScheme.outline.withValues(alpha: 0.3)
        : theme.colorScheme.outline.withValues(alpha: 0.2);
    final accentColor = theme.colorScheme.primary.withValues(
      alpha: isDark ? 0.9 : 0.8,
    );

    return Semantics(
      button: true,
      label: l10n.retellAiReviewTooltip,
      child: Tooltip(
        message: l10n.retellAiReviewTooltip,
        child: MouseRegion(
          // 桌面端保留手型指针（原 InkWell 由框架提供）
          cursor: isAiReviewLoading
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          child: TappableWrapper(
            key: const Key('retell_ai_review_button'),
            onTap: isAiReviewLoading ? null : onAiReviewTap,
            feedbackType: TapFeedback.opacity,
            pressedOpacity: 0.6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: borderColor),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isAiReviewLoading)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accentColor,
                      ),
                    )
                  else
                    Icon(
                      Icons.auto_awesome_rounded,
                      size: 16,
                      color: accentColor,
                    ),
                  const SizedBox(width: 6),
                  Text(
                    l10n.retellAiReviewTooltip,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: textColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 构建左侧反馈胶囊使用的 attempt。
  ///
  /// 只要有有效录音文件，就必须保留回放 badge。
  ///
  /// 评分开启且 ASR 成功时显示评分；关闭评分或 ASR 失败时统一降级为
  /// `unavailable + filePath`，让 [SpeechRatingBadge] 显示「录音」胶囊。
  SpeechPracticeAttempt? get _badgeAttempt {
    final attempt = currentAttempt;
    if (attempt == null) return null;
    if (!attempt.hasRecording) {
      return showRatingBadge && attempt.hasFinalFeedback ? attempt : null;
    }
    if (showRatingBadge && !attempt.isRecognitionFailure) {
      return attempt.hasFinalFeedback ? attempt : null;
    }
    return attempt.copyWith(
      status: SpeechPracticeAttemptStatus.unavailable,
      clearFinalTranscript: true,
      clearScore: true,
      clearTranscriptSegments: true,
      clearReferenceSegments: true,
    );
  }

  /// 中间内容（优先级：hintText > countdown > recording > empty）
  Widget _buildCenterContent() {
    // 播放中：显示提示文本
    if (hintText != null) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.headphones_rounded,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            hintText!,
            maxLines: 1,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    // 倒计时中
    if (showCountdown && countdownWidget != null) {
      return countdownWidget!;
    }

    // 停顿中：录音按钮
    if (isInPause) {
      return RecordingButton(mode: recordingMode, onTap: onRecordTap);
    }

    return const SizedBox.shrink();
  }

  /// 处理中提示：在线方式显示服务、模型与上传进度，其余沿用既有文案。
  String _processingText(BuildContext context) {
    final online = onlineStatus;
    if (online == null || online.isFailed) return l10n.listenAndRepeatAnalyzing;
    final percent = ((online.progress ?? 0) * 100).round();
    return l10n.shadowingOnlineProgress(
      online.serviceHost,
      online.modelId,
      percent,
    );
  }

  /// 在线转写在完成或失败后的状态行：费用、进度、可能计费与手动续试。
  Widget? _onlineStatusText(BuildContext context) {
    final online = onlineStatus;
    if (online == null) return null;
    final theme = Theme.of(context);
    if (online.isFailed) {
      final error = online.error;
      if (error == null) return null;
      final details = [
        speechErrorText(context, error),
        if (online.isChunked)
          l10n.shadowingOnlineChunkProgress(
            online.completedChunks,
            online.totalChunks,
          ),
        // 请求已发出但失败：供应商可能已计费，不能按免费或未发生处理。
        if (online.mayHaveBeenCharged) l10n.shadowingOnlineChargeWarning,
      ];
      final retry = online.retryable ? onRetryOnline : null;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                details.join(' · '),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.visible,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (retry != null)
              // 图标按钮宽度固定，长错误文案在窄屏仍能换行显示。
              IconButton(
                key: const Key('shadowing_online_retry'),
                onPressed: retry,
                tooltip: l10n.shadowingOnlineRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                style: IconButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(32, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
      );
    }
    if (!online.isCompleted) return null;
    final cost = online.reportedCost;
    return Text(
      cost == null
          ? l10n.shadowingOnlineCostUnknown(online.serviceHost, online.modelId)
          : l10n.shadowingOnlineCost(
              online.serviceHost,
              online.modelId,
              cost.toString(),
            ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  /// 错误文案允许更高的状态槽位（避免英文提示在窄屏截断）。
  bool get _usesExpandedStatusSlot =>
      currentAttempt?.errorMessage != null || (onlineStatus?.isFailed ?? false);

  /// 状态文字（在线转写结果 / 录音提示 / 错误信息）
  Widget? _buildStatusText(BuildContext context) {
    if (!isInPause || isProcessing) return null;

    final onlineText = _onlineStatusText(context);
    if (onlineText != null) return onlineText;

    final errorMessage = currentAttempt?.errorMessage;
    if (errorMessage != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          errorMessage,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.visible,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.error,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    if (recordingMode == RecordingButtonMode.recording) {
      return StatusLabel(text: l10n.listenAndRepeatRecordingInProgress);
    }

    return null;
  }
}
