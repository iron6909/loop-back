import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/providers.dart';
import '../models/word_timestamp.dart';
import '../services/app_logger.dart';
import '../utils/sense_group_service.dart';

/// 为多个字幕视图共享同一音频的词级时间戳加载结果。
final wordTimestampsProvider = FutureProvider.autoDispose
    .family<List<WordTimestamp>?, String>((ref, audioItemId) async {
      try {
        return await SenseGroupService().fetchWordTimestamps(
          audioItemId: audioItemId,
          dao: ref.watch(audioItemDaoProvider),
        );
      } catch (error, stackTrace) {
        AppLogger.log(
          'WordHighlight',
          'load timestamps failed audio=$audioItemId error=$error\n$stackTrace',
        );
        return null;
      }
    });
