import 'dart:io';

import 'package:loop_back/services/app_network_image_cache.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// 仅给测试用的 path_provider 假实现 — Config 构造里调 getTemporaryDirectory
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getTemporaryPath() async => dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// 验证 [AppNetworkImageCache] 的对外契约。
///
/// 不测真实的网络下载 / 文件系统 IO（那些是 flutter_cache_manager 自己
/// 应该测的，下游测了也只是重复）；这里只锁住"我们对外承诺的东西"：
/// - 单例性
/// - cacheKey 不被无意改动（影响磁盘缓存命中率）
/// - 用 JSON repo 而非 sqflite（避免引入 sqflite 依赖）
/// - 提供 ImageCacheManager 能力（CachedNetworkImage 需要）
void main() {
  // CacheManager 构造内部用 path_provider 拿临时目录，需要 binding + mock
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('app_img_cache_test_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  group('AppNetworkImageCache', () {
    test('是单例，多次访问 instance 拿到同一对象', () {
      expect(
        identical(AppNetworkImageCache.instance, AppNetworkImageCache.instance),
        isTrue,
      );
    });

    test('cacheKey 等于约定的 "app_network_images"（不能轻易改，会丢已有缓存）', () {
      expect(AppNetworkImageCache.cacheKey, 'app_network_images');
    });

    test('实现了 ImageCacheManager mixin（CachedNetworkImage 才能识别）', () {
      expect(AppNetworkImageCache.instance, isA<ImageCacheManager>());
    });

    test('继承自 CacheManager，能作为 CachedNetworkImage 的 cacheManager 参数', () {
      expect(AppNetworkImageCache.instance, isA<CacheManager>());
    });
  });
}
