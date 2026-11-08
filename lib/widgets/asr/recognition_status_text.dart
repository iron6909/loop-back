/// 识别设置的纯展示推导：方式名称、模型摘要、用途状态与在线阻断原因。
///
/// 页面、用途行与管理字幕弹窗共用这一份推导，避免同一个状态在两处各写一套文案。
library;

import '../../l10n/app_localizations.dart';
import '../../models/recognition_selection.dart';
import '../../providers/offline_asr_settings_provider.dart';
import '../../services/asr/asr_model_manager.dart';
import '../../services/speech/practice_online_transcriber.dart';

/// 用途名称。
String recognitionPurposeLabel(
  AppLocalizations l10n,
  RecognitionPurpose purpose,
) => switch (purpose) {
  RecognitionPurpose.subtitle => l10n.recognitionPurposeSubtitle,
  RecognitionPurpose.shadowing => l10n.recognitionPurposeShadowing,
  RecognitionPurpose.retell => l10n.recognitionPurposeRetell,
};

/// 方式名称。
String recognitionModeLabel(AppLocalizations l10n, RecognitionMode mode) =>
    switch (mode) {
      RecognitionMode.local => l10n.recognitionModeLocal,
      RecognitionMode.system => l10n.recognitionModeSystem,
      RecognitionMode.online => l10n.recognitionModeOnline,
    };

/// 在线方式不可选的原因说明；直接回答「还缺哪一步」。
String practiceOnlineBlockReasonText(
  AppLocalizations l10n,
  PracticeOnlineAccessDenial denial,
) => switch (denial) {
  PracticeOnlineAccessDenial.missingConfiguration =>
    l10n.recognitionOnlineNeedsConfiguration,
  PracticeOnlineAccessDenial.missingApiKey => l10n.recognitionOnlineNeedsApiKey,
  PracticeOnlineAccessDenial.uploadNoticeMissing =>
    l10n.recognitionOnlineNeedsUploadNotice,
  PracticeOnlineAccessDenial.capabilityUnverified =>
    l10n.recognitionOnlineNeedsVerification,
  PracticeOnlineAccessDenial.capabilityNotSuitable =>
    l10n.recognitionOnlineNeedsSuitableModel,
};

/// 当前选择的一行摘要：方式（本机带本地模型名，在线带在线模型 id）。
String recognitionSelectionSummary(
  AppLocalizations l10n,
  RecognitionSelection selection, {
  String onlineModelId = '',
}) {
  if (selection.usesOnlineModel) {
    return onlineModelId.isEmpty
        ? recognitionModeLabel(l10n, selection.mode)
        : l10n.recognitionOnlineModelSummary(onlineModelId);
  }
  if (!selection.usesLocalModel) {
    return recognitionModeLabel(l10n, selection.mode);
  }
  final model = availableModels
      .where((candidate) => candidate.id == selection.localModelId)
      .firstOrNull;
  return '${recognitionModeLabel(l10n, selection.mode)} · '
      '${model?.displayName ?? selection.localModelId}';
}

/// 用途行状态的语气：只决定状态点的颜色，文案本身由 [recognitionPurposeStatus] 给出。
enum RecognitionStatusTone {
  /// 现在就能用。
  ready,

  /// 还缺一步（未下载、下载中、尚未验证）。
  pending,

  /// 当前不可用（下载失败、未配置、缺 Key、模型不适配）。
  blocked,
}

/// 用途行的状态：语气决定状态点颜色，文字是用户看到的说明。
typedef RecognitionPurposeStatus = ({RecognitionStatusTone tone, String text});

/// 用途行的状态：本机看该用途自己档位的安装状态，系统看平台自带能力，在线看该用途
/// 自己的能力验证结论（字幕要片段时间戳，跟读与复述要文本）。
RecognitionPurposeStatus recognitionPurposeStatus(
  AppLocalizations l10n,
  RecognitionSelection selection, {
  required AsrModelState localModelState,
  required PracticeOnlineAccessDenial? onlineBlockReason,
}) {
  switch (selection.mode) {
    case RecognitionMode.system:
      return (
        tone: RecognitionStatusTone.ready,
        text: l10n.recognitionStatusSystemBuiltIn,
      );
    case RecognitionMode.online:
      return switch (onlineBlockReason) {
        null => (
          tone: RecognitionStatusTone.ready,
          text: l10n.recognitionStatusOnlineVerified,
        ),
        PracticeOnlineAccessDenial.missingConfiguration => (
          tone: RecognitionStatusTone.blocked,
          text: l10n.speechProviderStatusUnconfigured,
        ),
        PracticeOnlineAccessDenial.missingApiKey => (
          tone: RecognitionStatusTone.blocked,
          text: l10n.speechProviderStatusMissingKey,
        ),
        PracticeOnlineAccessDenial.capabilityNotSuitable => (
          tone: RecognitionStatusTone.blocked,
          text: l10n.recognitionStatusOnlineUnavailable,
        ),
        // 尚未验证与未告知都还没有该用途的能力结论。
        PracticeOnlineAccessDenial.capabilityUnverified ||
        PracticeOnlineAccessDenial.uploadNoticeMissing => (
          tone: RecognitionStatusTone.pending,
          text: l10n.speechCapabilityUnverified,
        ),
      };
    case RecognitionMode.local:
      return switch (localModelState.downloadStatus) {
        AsrModelDownloadStatus.downloaded => (
          tone: RecognitionStatusTone.ready,
          text: l10n.recognitionStatusLocalDownloaded,
        ),
        AsrModelDownloadStatus.downloading => (
          tone: RecognitionStatusTone.pending,
          text: l10n.recognitionStatusLocalDownloading,
        ),
        AsrModelDownloadStatus.failed => (
          tone: RecognitionStatusTone.blocked,
          text: l10n.recognitionStatusLocalDownloadFailed,
        ),
        AsrModelDownloadStatus.notDownloaded => (
          tone: RecognitionStatusTone.pending,
          text: l10n.recognitionStatusLocalNotDownloaded,
        ),
      };
  }
}
