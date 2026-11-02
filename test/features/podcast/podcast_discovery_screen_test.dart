import 'package:echo_loop/features/auth/providers/auth_providers.dart';
import 'package:echo_loop/features/podcast/data/featured_podcast_service.dart';
import 'package:echo_loop/features/podcast/models/featured_podcast.dart';
import 'package:echo_loop/features/podcast/podcast_preview_provider.dart';
import 'package:echo_loop/features/podcast/podcast_models.dart';
import 'package:echo_loop/features/podcast/podcast_repository.dart';
import 'package:echo_loop/features/podcast/podcast_search_provider.dart';
import 'package:echo_loop/features/podcast/podcast_search_service.dart';
import 'package:echo_loop/features/podcast/screens/podcast_discovery_screen.dart';
import 'package:echo_loop/features/podcast/widgets/podcast_subscribe_tile.dart';
import 'package:echo_loop/models/collection.dart';
import 'package:echo_loop/providers/collection_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/mock_providers.dart';
import '../../helpers/test_app.dart';

class _FakeSearchService extends PodcastSearchService {
  _FakeSearchService(this.results);

  final List<PodcastSearchResult> results;
  String? lastTerm;

  @override
  Future<List<PodcastSearchResult>> search(
    String term, {
    int limit = 25,
  }) async {
    lastTerm = term;
    return results;
  }
}

class _FakePodcastRepository extends Fake implements PodcastRepository {
  final List<String> subscribed = [];
  final List<String?> knownFeedUrls = [];

  @override
  Future<Collection> createAndFetch(
    String inputUrl, {
    String? knownFeedUrl,
  }) async {
    subscribed.add(inputUrl);
    knownFeedUrls.add(knownFeedUrl);
    return Collection(
      id: 'subscribed',
      name: 'Subscribed',
      createdDate: DateTime(2026, 1, 1),
      source: CollectionSource.podcast,
      podcastInputUrl: inputUrl,
      podcastFeedUrl: knownFeedUrl ?? inputUrl,
    );
  }
}

class _FakeFeaturedPodcastService extends Fake
    implements FeaturedPodcastService {
  _FakeFeaturedPodcastService(this.podcasts, {this.failOnce = false});
  final List<FeaturedPodcast> podcasts;
  bool failOnce;
  int calls = 0;
  @override
  Future<List<FeaturedPodcast>> load() async {
    calls++;
    if (failOnce) {
      failOnce = false;
      throw const FormatException('Invalid asset');
    }
    return podcasts;
  }
}

FeaturedPodcast _featuredPodcast({
  String id = 'featured-1',
  String title = 'Featured English',
  String applePodcastUrl = '',
  String rssUrl = 'https://example.com/feed.xml',
}) => FeaturedPodcast(
  id: id,
  applePodcastUrl: applePodcastUrl,
  rssUrl: rssUrl,
  imageUrl: null,
  title: title,
  description: 'Short English lessons',
);

_FakeFeaturedPodcastService _serviceWithPodcasts(
  List<FeaturedPodcast> podcasts,
) => _FakeFeaturedPodcastService(podcasts);

void main() {
  testWidgets('随包精选为空时显示空态，搜索入口保留', (tester) async {
    final service = _serviceWithPodcasts(const []);
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [featuredPodcastServiceProvider.overrideWithValue(service)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No curated podcasts yet'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsNothing);
    expect(service.calls, 1);
  });

  testWidgets('显示随包精选，清空搜索后仍使用本地清单', (tester) async {
    final service = _serviceWithPodcasts([_featuredPodcast()]);
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [featuredPodcastServiceProvider.overrideWithValue(service)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Featured English'), findsOneWidget);
    expect(find.text('Short English lessons'), findsOneWidget);
    expect(service.calls, 1);
  });

  testWidgets('资源加载失败后重试读取清单', (tester) async {
    final service = _FakeFeaturedPodcastService([
      _featuredPodcast(),
    ], failOnce: true);
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [featuredPodcastServiceProvider.overrideWithValue(service)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Featured English'), findsOneWidget);
    expect(service.calls, 2);
  });

  testWidgets('滚动到随包清单底部不再发起分页读取', (tester) async {
    final service = _serviceWithPodcasts([
      for (var i = 0; i < 25; i++)
        _featuredPodcast(id: 'podcast-$i', title: 'Podcast $i'),
    ]);
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [featuredPodcastServiceProvider.overrideWithValue(service)],
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(service.calls, 1);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('精选 Podcast 订阅优先使用 Apple URL 且停留在本页', (tester) async {
    final fakeRepo = _FakePodcastRepository();
    final service = _serviceWithPodcasts([
      _featuredPodcast(applePodcastUrl: 'https://podcasts.apple.com/example'),
    ]);
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [
          featuredPodcastServiceProvider.overrideWithValue(service),
          isAuthenticatedProvider.overrideWithValue(true),
          podcastRepositoryProvider.overrideWithValue(fakeRepo),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_circle_outline).first);
    await tester.pumpAndSettle();

    expect(fakeRepo.subscribed, ['https://podcasts.apple.com/example']);
    expect(fakeRepo.knownFeedUrls, ['https://example.com/feed.xml']);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Added to My Collections'), findsWidgets);
  });

  testWidgets('已订阅的精选 Podcast 显示静态对勾而不是去学习', (tester) async {
    final service = _serviceWithPodcasts([_featuredPodcast()]);
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [
          featuredPodcastServiceProvider.overrideWithValue(service),
          collectionListProvider.overrideWith(
            () => TestCollectionList(
              CollectionState(
                rawCollections: [
                  Collection(
                    id: 'existing',
                    name: 'Existing Podcast',
                    createdDate: DateTime(2026, 1, 1),
                    source: CollectionSource.podcast,
                    podcastFeedUrl: 'https://example.com/feed.xml',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
    expect(find.text('Added'), findsOneWidget);
    expect(find.text('Start Practicing'), findsNothing);
    expect(find.byIcon(Icons.add_circle_outline), findsNothing);

    final tileRect = tester.getRect(find.byType(PodcastSubscribeTile));
    final badgeRect = tester.getRect(find.text('Added'));
    final checkRect = tester.getRect(
      find.byIcon(Icons.check_circle_outline_rounded),
    );
    expect(badgeRect.top, greaterThanOrEqualTo(tileRect.top));
    expect(badgeRect.bottom, lessThan(checkRect.top));
  });

  testWidgets('未登录可订阅精选 Podcast，不读取认证状态', (tester) async {
    final fakeRepo = _FakePodcastRepository();
    final service = _serviceWithPodcasts([_featuredPodcast()]);
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [
          featuredPodcastServiceProvider.overrideWithValue(service),
          isAuthenticatedProvider.overrideWith((ref) {
            fail('播客订阅不应读取认证状态');
          }),
          podcastRepositoryProvider.overrideWithValue(fakeRepo),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_circle_outline).first);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(fakeRepo.subscribed, ['https://example.com/feed.xml']);
  });

  testWidgets('进入页面时搜索框不会自动聚焦', (tester) async {
    final service = _serviceWithPodcasts(const []);
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [featuredPodcastServiceProvider.overrideWithValue(service)],
      ),
    );
    await tester.pumpAndSettle();

    final editableText = tester.widget<EditableText>(find.byType(EditableText));
    expect(editableText.focusNode.hasFocus, isFalse);
  });

  testWidgets('输入关键词展示 Apple 搜索结果', (tester) async {
    final fakeSearch = _FakeSearchService([
      const PodcastSearchResult(
        id: 's1',
        title: 'BBC Global News',
        author: 'BBC',
        feedUrl: 'https://feeds.bbc.co.uk/news.xml',
      ),
    ]);
    final service = _serviceWithPodcasts(const []);
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [
          featuredPodcastServiceProvider.overrideWithValue(service),
          podcastSearchServiceProvider.overrideWithValue(fakeSearch),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'bbc');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('BBC Global News'), findsOneWidget);
    expect(fakeSearch.lastTerm, 'bbc');
  });

  testWidgets('输入链接解析为可订阅 item', (tester) async {
    const url = 'https://example.com/feed.xml';
    final service = _serviceWithPodcasts(const []);
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [
          featuredPodcastServiceProvider.overrideWithValue(service),
          podcastPreviewProvider(url).overrideWith(
            (ref) async => const PodcastPreviewData(
              meta: PodcastFeedMeta(
                title: 'Example Cast',
                feedUrl: url,
                author: 'Example Author',
              ),
              episodes: [],
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), url);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Example Cast'), findsOneWidget);
    expect(find.text('Subscribe to this link'), findsNothing);
  });

  testWidgets('未登录可订阅粘贴的 RSS 和 Apple 链接', (tester) async {
    for (final url in [
      'https://example.com/feed.xml',
      'https://podcasts.apple.com/us/podcast/example/id123456',
    ]) {
      final fakeRepo = _FakePodcastRepository();
      await tester.pumpWidget(
        createTestApp(
          const PodcastDiscoveryScreen(),
          overrides: [
            featuredPodcastServiceProvider.overrideWithValue(
              _serviceWithPodcasts(const []),
            ),
            isAuthenticatedProvider.overrideWith((ref) {
              fail('粘贴链接订阅不应读取认证状态');
            }),
            podcastRepositoryProvider.overrideWithValue(fakeRepo),
            podcastPreviewProvider(url).overrideWith(
              (ref) async => const PodcastPreviewData(
                meta: PodcastFeedMeta(
                  title: 'Example Cast',
                  feedUrl: 'https://example.com/feed.xml',
                ),
                episodes: [],
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), url);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add_circle_outline).first);
      await tester.pumpAndSettle();

      expect(fakeRepo.subscribed, [url]);
      expect(find.byType(AlertDialog), findsNothing);
    }
  });
}
