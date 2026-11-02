import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo_loop/features/podcast/data/featured_podcast_service.dart';

class _CatalogBundle extends CachingAssetBundle {
  _CatalogBundle(this.content);
  final String content;
  final paths = <String>[];
  @override
  Future<ByteData> load(String key) async {
    paths.add(key);
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(content)));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('随包清单可解析，读取只经过 AssetBundle 且保留 Apple 优先订阅', () async {
    final bundle = _CatalogBundle(
      '[{"id":"one","title":"English","applePodcastUrl":"https://podcasts.apple.com/podcast/id1","rssUrl":"https://example.com/feed.xml"}]',
    );
    final podcasts = await FeaturedPodcastService(bundle: bundle).load();
    expect(bundle.paths, ['assets/podcast/catalog.json']);
    expect(podcasts.single.title, 'English');
    expect(
      podcasts.single.subscriptionInputUrl,
      'https://podcasts.apple.com/podcast/id1',
    );
  });
  test('正式随包清单非空且每项有独立 ID 和可订阅地址', () async {
    final podcasts = await FeaturedPodcastService().load();
    expect(podcasts, isNotEmpty);
    expect(podcasts.map((p) => p.id).toSet().length, podcasts.length);
    for (final podcast in podcasts) {
      expect(Uri.parse(podcast.subscriptionInputUrl).host, isNotEmpty);
      expect(podcast.title, isNotEmpty);
    }
  });
  test('清单损坏或无条目列表明确失败', () async {
    await expectLater(
      FeaturedPodcastService(bundle: _CatalogBundle('{}')).load(),
      throwsFormatException,
    );
  });
}
