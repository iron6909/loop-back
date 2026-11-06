/// 本地功能配置。
///
/// 后端 Config API 已停用：此处只返回编译期默认值，不读旧缓存、不发请求。
library;

import 'remote_config.dart';

class RemoteConfigService {
  const RemoteConfigService();

  /// 兼容字段：不再有远端拉取时间。
  DateTime? get lastFetchedAt => null;

  RemoteConfig loadInitialFromCache() => RemoteConfig.defaults;

  Future<RemoteConfig> load() async => RemoteConfig.defaults;

  Future<RemoteConfig> fetchRemote() async => RemoteConfig.defaults;

  Future<RemoteConfig> fetchRemoteFromBaseUrl(
    String baseUrl, {
    required Duration timeout,
  }) async => RemoteConfig.defaults;
}
