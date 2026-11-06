import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/featured_podcast.dart';

/// 精选播客随包发布，只读资源文件，不再创建 HTTP 客户端或维护分页缓存。
class FeaturedPodcastService {
  FeaturedPodcastService({AssetBundle? bundle})
    : _bundle = bundle ?? rootBundle;
  final AssetBundle _bundle;

  Future<List<FeaturedPodcast>> load() async {
    final raw = jsonDecode(
      await _bundle.loadString('assets/podcast/catalog.json'),
    );
    if (raw is! List<Object?>) {
      throw const FormatException('Invalid podcast catalog');
    }
    return List.unmodifiable(
      raw.map((entry) {
        if (entry is! Map<String, Object?>) {
          throw const FormatException('Invalid podcast entry');
        }
        return FeaturedPodcast.fromJson(entry);
      }),
    );
  }
}

final featuredPodcastServiceProvider = Provider<FeaturedPodcastService>(
  (ref) => FeaturedPodcastService(),
);
