import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/playback_settings.dart';
import 'app_logger.dart';

class ListeningPracticeSettingsStore {
  const ListeningPracticeSettingsStore({
    this.full = const PlaybackSettings(),
    this.bookmark = kDefaultBookmarkPlaybackSettings,
  });

  final PlaybackSettings full;
  final PlaybackSettings bookmark;
}

/// SharedPreferences 存储服务
/// 保留纯设置项的存取（PlaybackSettings）
class StorageService {
  static const String _settingsKey = 'playback_settings';

  // Free Player 播放设置：全文 / 收藏两套独立配置
  static Future<ListeningPracticeSettingsStore> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_settingsKey);
    if (jsonString == null) return const ListeningPracticeSettingsStore();

    try {
      final jsonMap = json.decode(jsonString);
      if (jsonMap is! Map<String, dynamic>) {
        return const ListeningPracticeSettingsStore();
      }

      final fullRaw = jsonMap['fullSettings'];
      final bookmarkRaw = jsonMap['bookmarkSettings'];
      if (fullRaw is Map<String, dynamic> &&
          bookmarkRaw is Map<String, dynamic>) {
        final bookmarkSettings = PlaybackSettings.fromJson(bookmarkRaw);
        final hasPersistedLoopSwitches =
            bookmarkRaw.containsKey('loopWhole') ||
            bookmarkRaw.containsKey('loopSentence');
        return ListeningPracticeSettingsStore(
          full: PlaybackSettings.fromJson(fullRaw),
          bookmark: hasPersistedLoopSwitches
              ? bookmarkSettings
              : withBookmarkLoopDefaults(bookmarkSettings),
        );
      }

      // 旧 schema：只有一份全局设置。升级后全文保留旧偏好，收藏切到新的默认循环。
      final legacy = PlaybackSettings.fromJson(jsonMap);
      return ListeningPracticeSettingsStore(
        full: legacy,
        bookmark: withBookmarkLoopDefaults(legacy),
      );
    } catch (e) {
      AppLogger.log('StorageService', '读取播放设置失败，回退默认值: $e');
      return const ListeningPracticeSettingsStore();
    }
  }

  static Future<void> saveSettings(
    ListeningPracticeSettingsStore settings,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = json.encode({
      'fullSettings': settings.full.toJson(),
      'bookmarkSettings': settings.bookmark.toJson(),
    });
    await prefs.setString(_settingsKey, jsonString);
  }
}
