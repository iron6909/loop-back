/// 转录偏好：短句合并。
///
/// 识别语言固定为英语、模型在语音识别设置里按用途选择，都不在弹窗里重复提供。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_localizations.dart';
import '../providers/settings_provider.dart';

/// 与既有偏好共用同一来源，弹窗不再维护一份镜像。
final transcriptionMergeEnabledProvider = Provider<bool>(
  (ref) => ref.watch(
    appSettingsProvider.select((s) => s.aiTranscriptionAutoMergeEnabled),
  ),
);

class TranscriptionOptions extends ConsumerWidget {
  const TranscriptionOptions({super.key});

  /// 只保留与转录行为相关的偏好。
  ///
  /// 识别语言固定为英语（三档 Whisper 均为英语模型，在线请求也固定告知语种为
  /// 英语），模型选择统一在语音识别设置里按用途维护，弹窗不再重复提供。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        Text(l10n.transcriptionTimingNotice),
        SwitchListTile(
          title: Text(l10n.autoMergeShortSentences),
          subtitle: Text(l10n.autoMergeShortSentencesHint),
          value: ref.watch(transcriptionMergeEnabledProvider),
          onChanged: (value) => ref
              .read(appSettingsProvider.notifier)
              .setAiTranscriptionAutoMergeEnabled(value),
        ),
      ],
    );
  }
}
