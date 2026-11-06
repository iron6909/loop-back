import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/audio_item.dart';

/// 仅在历史社区条目显示时检查文件，不改写音频、字幕或学习记录。
final communityMediaAvailableProvider = FutureProvider.autoDispose
    .family<bool, AudioItem>((ref, item) async {
      final path = await item.getFullAudioPath();
      if (path == null) return false;
      try {
        return await File(path).exists();
      } on FileSystemException {
        return false;
      }
    });
