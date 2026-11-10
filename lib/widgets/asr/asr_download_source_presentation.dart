/// 下载来源展示辅助
///
/// 集中管理 `AsrDownloadSource → 展示文案` 映射，供语音识别设置页与词典设置页
/// 共用，避免两处逐字相同的 switch 造成两个真相源。
library;

import '../../l10n/app_localizations.dart';
import '../../services/asr/asr_model_catalog.dart';

/// 取下载来源的展示文案。
String asrDownloadSourceLabel(
  AppLocalizations l10n,
  AsrDownloadSource source,
) => switch (source) {
  AsrDownloadSource.huggingFace => l10n.asrDownloadSourceHuggingFace,
  AsrDownloadSource.huggingFaceMirror =>
    l10n.asrDownloadSourceHuggingFaceMirror,
};
