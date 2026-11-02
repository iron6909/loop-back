import 'dart:io';

import 'package:echo_loop/features/community_collections/providers/community_media_available_provider.dart';
import 'package:echo_loop/models/audio_item.dart';
import 'package:echo_loop/utils/app_data_dir.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('历史社区媒体按真实文件存在性判断，不改写条目或学习数据', () async {
    final dataDir = await Directory.systemTemp.createTemp('community_media_');
    appDataDirectoryOverride = dataDir;
    final container = ProviderContainer();
    addTearDown(() async {
      container.dispose();
      appDataDirectoryOverride = null;
      await dataDir.delete(recursive: true);
    });
    final file = File('${dataDir.path}/lesson.mp3');
    await file.writeAsBytes([1, 2, 3]);
    AudioItem item(String? path) => AudioItem(
      id: 'old-audio',
      name: 'Old lesson',
      addedDate: DateTime(2026),
      remoteAudioId: 'remote-id',
      audioPath: path,
    );
    final downloaded = item('lesson.mp3');
    expect(
      await container.read(communityMediaAvailableProvider(downloaded).future),
      isTrue,
    );
    expect(
      await container.read(communityMediaAvailableProvider(item(null)).future),
      isFalse,
    );
    expect(
      await container.read(
        communityMediaAvailableProvider(item('missing.mp3')).future,
      ),
      isFalse,
    );
    expect(downloaded.audioPath, 'lesson.mp3');
    expect(await file.readAsBytes(), [1, 2, 3]);
  });
}
