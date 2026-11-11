import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/collection.dart';

void main() {
  group('Collection', () {
    final now = DateTime(2026, 1, 15);

    Collection createSample() {
      return Collection(
        id: 'col-1',
        name: '我的合集',
        createdDate: now,
        isPinned: true,
      );
    }

    group('fromJson', () {
      test('完整字段解析', () {
        final json = {
          'id': 'col-1',
          'name': '我的合集',
          'createdDate': now.toIso8601String(),
          'isPinned': true,
          'audioItemIds': ['a1', 'a2'], // 旧格式兼容
        };
        final col = Collection.fromJson(json);

        expect(col.id, 'col-1');
        expect(col.name, '我的合集');
        expect(col.createdDate, now);
        expect(col.updatedAt, now);
        expect(col.isPinned, true);
      });

      test('解析 updatedAt，旧数据缺失时回退 createdDate', () {
        final updatedAt = DateTime(2026, 1, 16);
        final withUpdatedAt = Collection.fromJson({
          'id': 'col-1',
          'name': '新格式',
          'createdDate': now.toIso8601String(),
          'updatedAt': updatedAt.toIso8601String(),
        });
        final legacy = Collection.fromJson({
          'id': 'col-2',
          'name': '旧格式',
          'createdDate': now.toIso8601String(),
        });

        expect(withUpdatedAt.updatedAt, updatedAt);
        expect(legacy.updatedAt, now);
      });

      test('兼容旧 isStarred key', () {
        final json = {
          'id': 'col-1',
          'name': '旧格式',
          'createdDate': now.toIso8601String(),
          'isStarred': true,
        };
        final col = Collection.fromJson(json);
        expect(col.isPinned, true);
      });

      test('处理缺失可选字段', () {
        final json = {
          'id': 'col-1',
          'name': '测试',
          'createdDate': now.toIso8601String(),
        };
        final col = Collection.fromJson(json);

        expect(col.isPinned, isFalse);
      });
    });

    group('audioItemIdsFromJson（迁移用）', () {
      test('提取旧格式中的 audioItemIds', () {
        final json = {
          'id': 'col-1',
          'name': '测试',
          'createdDate': now.toIso8601String(),
          'audioItemIds': ['a1', 'a2', 'a3'],
        };
        expect(Collection.audioItemIdsFromJson(json), ['a1', 'a2', 'a3']);
      });

      test('缺失 audioItemIds 返回空列表', () {
        final json = {
          'id': 'col-1',
          'name': '测试',
          'createdDate': now.toIso8601String(),
        };
        expect(Collection.audioItemIdsFromJson(json), isEmpty);
      });
    });

    group('copyWith', () {
      test('部分字段覆盖', () {
        final col = createSample();
        final updatedAt = DateTime(2026, 1, 16);
        final copied = col.copyWith(
          name: '新合集',
          isPinned: false,
          updatedAt: updatedAt,
        );

        expect(copied.name, '新合集');
        expect(copied.isPinned, isFalse);
        expect(copied.updatedAt, updatedAt);
        expect(copied.id, col.id);
      });
    });

    group('社区合集字段', () {
      test('默认 source=local，isCommunity=false', () {
        final col = createSample();
        expect(col.source, CollectionSource.local);
        expect(col.isCommunity, isFalse);
        expect(col.remoteId, isNull);
        expect(col.coverUrl, isNull);
        expect(col.description, isNull);
        expect(col.deprecatedAt, isNull);
        expect(col.isDeprecated, isFalse);
      });

      test('社区合集字段齐备时 isCommunity=true', () {
        final col = Collection(
          id: 'col-1',
          name: 'TED 精选',
          createdDate: now,
          source: CollectionSource.community,
          remoteId: 'remote-uuid-1',
          coverUrl: 'https://cdn/x.png',
          description: '精选演讲',
        );
        expect(col.isCommunity, isTrue);
        expect(col.remoteId, 'remote-uuid-1');
      });

      test('deprecatedAt 非 null → isDeprecated=true', () {
        final col = Collection(
          id: 'col-1',
          name: 'TED 精选',
          createdDate: now,
          source: CollectionSource.community,
          remoteId: 'remote-uuid-1',
          deprecatedAt: now,
        );
        expect(col.isDeprecated, isTrue);
      });

      test('CollectionSource.fromString 解析未知值回退到 local', () {
        expect(CollectionSource.fromString(null), CollectionSource.local);
        expect(
          CollectionSource.fromString('official'),
          CollectionSource.community,
        );
        expect(CollectionSource.fromString('local'), CollectionSource.local);
        expect(CollectionSource.fromString('unknown'), CollectionSource.local);
      });

      test('CollectionSource.storageValue 与后端/DB 字符串对齐', () {
        expect(CollectionSource.local.storageValue, 'local');
        expect(CollectionSource.community.storageValue, 'community');
      });

      test('fromJson 处理社区合集新字段', () {
        final json = {
          'id': 'col-1',
          'name': 'TED',
          'createdDate': now.toIso8601String(),
          'source': 'official',
          'remoteId': 'r1',
          'coverUrl': 'https://cdn/x.png',
          'coverUrlChina': 'https://cn.cdn/x.png',
          'description': 'desc',
          'deprecatedAt': now.toIso8601String(),
        };
        final col = Collection.fromJson(json);
        expect(col.source, CollectionSource.community);
        expect(col.remoteId, 'r1');
        expect(col.coverUrl, 'https://cdn/x.png');
        expect(col.coverUrlChina, 'https://cn.cdn/x.png');
        expect(col.description, 'desc');
        expect(col.deprecatedAt, now);
      });

      test('fromJson 忽略非字符串的中国封面 URL', () {
        final col = Collection.fromJson({
          'id': 'col-1',
          'name': '旧合集',
          'createdDate': now.toIso8601String(),
          'coverUrlChina': 42,
        });

        expect(col.coverUrlChina, isNull);
      });

      test('fromJson 老数据无 source 字段默认 local', () {
        final json = {
          'id': 'col-1',
          'name': '旧',
          'createdDate': now.toIso8601String(),
        };
        final col = Collection.fromJson(json);
        expect(col.source, CollectionSource.local);
      });

      test('copyWith 能独立覆盖社区合集字段', () {
        final col = createSample();
        final copied = col.copyWith(
          source: CollectionSource.community,
          remoteId: 'r1',
          coverUrl: 'c',
          description: 'd',
        );
        expect(copied.isCommunity, isTrue);
        expect(copied.remoteId, 'r1');
        expect(copied.coverUrl, 'c');
        expect(copied.description, 'd');
      });
    });
  });
}
