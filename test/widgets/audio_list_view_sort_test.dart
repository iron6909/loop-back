import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/audio_item.dart';
import 'package:loop_back/providers/audio_list_settings_provider.dart';
import 'package:loop_back/widgets/audio_list_view.dart';

/// 本地轻量构造，避免引入 `../helpers/mock_providers.dart`（pre-existing
/// 编译错误会让整个文件无法 load）。
AudioItem _item({
  required String id,
  String name = 'n',
  DateTime? addedDate,
  bool isPinned = false,
  DateTime? originalDate,
}) {
  return AudioItem(
    id: id,
    name: name,
    audioPath: 'audios/$id.m4a',
    addedDate: addedDate ?? DateTime(2026, 1, 1),
    isPinned: isPinned,
    originalDate: originalDate,
  );
}

void main() {
  group('sortAudioItems 置顶排序', () {
    final jan1 = DateTime(2026, 1, 1);
    final jan5 = DateTime(2026, 1, 5);
    final jan10 = DateTime(2026, 1, 10);
    final jan15 = DateTime(2026, 1, 15);

    AudioItem item(
      String id,
      String name,
      DateTime date, {
      bool pinned = false,
    }) {
      return _item(id: id, name: name, addedDate: date, isPinned: pinned);
    }

    test('置顶项始终排在最前面（dateDesc）', () {
      final items = [
        item('a1', 'Audio A', jan10),
        item('a2', 'Audio B', jan5, pinned: true),
        item('a3', 'Audio C', jan1),
      ];

      final sorted = sortAudioItems(items, AudioSortType.dateDesc);
      final ids = sorted.map((i) => i.id).toList();

      // 置顶区：a2；非置顶区按日期倒序：a1, a3
      expect(ids, ['a2', 'a1', 'a3']);
    });

    test('置顶项始终排在最前面（nameAsc）', () {
      final items = [
        item('a1', 'Zebra', jan10),
        item('a2', 'Apple', jan5, pinned: true),
        item('a3', 'Mango', jan1),
      ];

      final sorted = sortAudioItems(items, AudioSortType.nameAsc);
      final ids = sorted.map((i) => i.id).toList();

      // 置顶区：a2；非置顶区按名称升序：a3(Mango), a1(Zebra)
      expect(ids, ['a2', 'a3', 'a1']);
    });

    test('非置顶项按选定排序类型排列，不受置顶影响', () {
      final items = [
        item('a1', 'Banana', jan10),
        item('a2', 'Apple', jan5, pinned: true),
        item('a3', 'Cherry', jan1),
        item('a4', 'Date', jan15),
      ];

      final sorted = sortAudioItems(items, AudioSortType.nameDesc);
      final unpinnedIds = sorted
          .where((i) => !i.isPinned)
          .map((i) => i.id)
          .toList();

      // 非置顶按名称降序：Date, Cherry, Banana
      expect(unpinnedIds, ['a4', 'a3', 'a1']);
    });

    test('多个置顶项之间按添加日期倒序排列', () {
      final items = [
        item('a1', 'Z', jan1, pinned: true),
        item('a2', 'A', jan10, pinned: true),
        item('a3', 'M', jan5),
      ];

      final sorted = sortAudioItems(items, AudioSortType.nameAsc);
      final ids = sorted.map((i) => i.id).toList();

      // 置顶区按日期倒序：a2(jan10), a1(jan1)；非置顶区：a3
      expect(ids, ['a2', 'a1', 'a3']);
    });

    test('全部置顶时按添加日期倒序排列', () {
      final items = [
        item('a1', 'C', jan1, pinned: true),
        item('a2', 'A', jan10, pinned: true),
        item('a3', 'B', jan5, pinned: true),
      ];

      final sorted = sortAudioItems(items, AudioSortType.nameAsc);
      final ids = sorted.map((i) => i.id).toList();

      // 全部置顶，按日期倒序
      expect(ids, ['a2', 'a3', 'a1']);
    });

    test('无置顶时排序行为与普通排序一致', () {
      final items = [
        item('a1', 'Banana', jan10),
        item('a2', 'Apple', jan5),
        item('a3', 'Cherry', jan1),
      ];

      final sorted = sortAudioItems(items, AudioSortType.nameAsc);
      final names = sorted.map((i) => i.name).toList();

      expect(names, ['Apple', 'Banana', 'Cherry']);
    });

    test('dateAsc 排序下置顶项仍在前面', () {
      final items = [
        item('a1', 'A', jan15),
        item('a2', 'B', jan1, pinned: true),
        item('a3', 'C', jan5),
        item('a4', 'D', jan10),
      ];

      final sorted = sortAudioItems(items, AudioSortType.dateAsc);
      final ids = sorted.map((i) => i.id).toList();

      // 置顶区：a2；非置顶区按日期升序：a3(jan5), a4(jan10), a1(jan15)
      expect(ids, ['a2', 'a3', 'a4', 'a1']);
    });

    test('空列表不报错', () {
      final sorted = sortAudioItems([], AudioSortType.dateDesc);
      expect(sorted, isEmpty);
    });
  });

  group('sortAudioItems custom / originalDate', () {
    AudioItem mk(
      String id, {
      String name = 'n',
      DateTime? original,
      bool pinned = false,
    }) {
      return _item(
        id: id,
        name: name,
        isPinned: pinned,
        originalDate: original,
      );
    }

    test('custom 保持传入顺序（但置顶项提前）', () {
      final items = [mk('a'), mk('b', pinned: true), mk('c')];
      final sorted = sortAudioItems(items, AudioSortType.custom);
      expect(sorted.map((i) => i.id).toList(), ['b', 'a', 'c']);
    });

    test('originalDateAsc：升序，null 排到末尾', () {
      final items = [
        mk('a', original: DateTime.utc(2023, 1, 1)),
        mk('b'), // null
        mk('c', original: DateTime.utc(2020, 5, 1)),
      ];
      final sorted = sortAudioItems(items, AudioSortType.originalDateAsc);
      expect(sorted.map((i) => i.id).toList(), ['c', 'a', 'b']);
    });

    test('originalDateDesc：降序，null 排到末尾', () {
      final items = [
        mk('a', original: DateTime.utc(2023, 1, 1)),
        mk('b'), // null
        mk('c', original: DateTime.utc(2020, 5, 1)),
      ];
      final sorted = sortAudioItems(items, AudioSortType.originalDateDesc);
      expect(sorted.map((i) => i.id).toList(), ['a', 'c', 'b']);
    });
  });
}
