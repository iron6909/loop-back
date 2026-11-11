import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/audio_item.dart';
import 'package:loop_back/widgets/audio_list_view.dart';

/// 轻量构造，允许显式指定 audioPath 以模拟共享文件场景。
AudioItem _item({required String id, String? audioPath = 'audios/x.m4a'}) {
  return AudioItem(
    id: id,
    name: id,
    audioPath: audioPath,
    addedDate: DateTime(2026, 1, 1),
  );
}

void main() {
  group('isAudioFileSharedByOthers', () {
    test('唯一引用该文件时返回 false', () {
      final target = _item(id: 'a1', audioPath: 'audios/only.m4a');
      final items = [target, _item(id: 'a2', audioPath: 'audios/other.m4a')];

      expect(isAudioFileSharedByOthers(items, target), isFalse);
    });

    test('其他条目共享同一 audioPath 时返回 true', () {
      final target = _item(id: 'a1', audioPath: 'audios/shared.m4a');
      final items = [target, _item(id: 'a2', audioPath: 'audios/shared.m4a')];

      expect(isAudioFileSharedByOthers(items, target), isTrue);
    });

    test('audioPath 为空（未就绪）时返回 false', () {
      final target = _item(id: 'a1', audioPath: null);
      final items = [target, _item(id: 'a2', audioPath: null)];

      expect(isAudioFileSharedByOthers(items, target), isFalse);
    });
  });
}
