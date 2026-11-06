import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/featured_podcast_service.dart';
import '../models/featured_podcast.dart';

/// 读取随包精选播客；加载失败可 invalidate 重读资源。
final featuredPodcastsProvider = FutureProvider<List<FeaturedPodcast>>((ref) {
  return ref.watch(featuredPodcastServiceProvider).load();
});
