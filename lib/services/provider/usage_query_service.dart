/// 按当前供应商查询只读用量
///
/// 三条硬规则（spec「用量数据形状」）：
/// 1. 失败保留上次成功值并记录时间，从未成功则显示暂无法获取；
/// 2. 60 秒内复用上次结果，并发刷新合并为一次请求；
/// 3. 不认识的主机一律「不支持查询」，**不**把凭据发往未知端点。
///
/// 用量是附加信息：任何失败都不得阻止推理请求。
library;

import 'package:dio/dio.dart';

import 'provider_config.dart';
import 'provider_http_client.dart';
import 'usage_mapper.dart';
import 'usage_models.dart';

/// 用量卡的展示态。
class UsageView {
  const UsageView({
    this.snapshot,
    this.fetchedAt,
    this.failed = false,
    this.unsupported = false,
  });

  /// 最近一次成功映射的结果；从未成功时为 null。
  final UsageSnapshot? snapshot;

  /// 最近一次成功的时间。
  final DateTime? fetchedAt;

  /// 本次刷新失败（[snapshot] 可能仍是旧值）。
  final bool failed;

  /// 该地址不支持用量查询。
  final bool unsupported;

  /// 是否有可展示的数据。
  bool get hasData => snapshot != null;
}

/// 用量查询服务。
class UsageQueryService {
  UsageQueryService({
    required ProviderHttpClient http,
    required ProviderConfig config,
    Duration cacheTtl = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _http = http,
       _config = config,
       _ttl = cacheTtl,
       _now = now ?? DateTime.now;

  final ProviderHttpClient _http;
  final ProviderConfig _config;
  final Duration _ttl;
  final DateTime Function() _now;

  UsageView _view = const UsageView();
  Future<UsageView>? _inflight;
  int _generation = 0;
  CancelToken? _cancel;

  /// 当前展示态（不触发请求）。
  UsageView get current => _view;

  /// 配置或 Key 变更时作废旧刷新，避免旧结果写回新配置界面。
  void invalidate() {
    _generation++;
    _cancel?.cancel('provider changed');
    _inflight = null;
    _view = const UsageView();
  }

  /// 刷新用量；[force] 为 false 且缓存未过期时直接复用。
  Future<UsageView> refresh({bool force = false}) {
    final inFlight = _inflight;
    if (inFlight != null) return inFlight;

    final fetchedAt = _view.fetchedAt;
    final fresh =
        !force && fetchedAt != null && _now().difference(fetchedAt) < _ttl;
    if (fresh) return Future.value(_view);

    final generation = _generation;
    final token = CancelToken();
    _cancel = token;
    final pending = _fetch(generation, token);
    _inflight = pending;
    return pending.whenComplete(() {
      if (generation == _generation) _inflight = null;
    });
  }

  Future<UsageView> _fetch(int generation, CancelToken token) async {
    final uri = _endpoint();
    if (uri == null) {
      return _commit(const UsageView(unsupported: true), generation);
    }
    try {
      final snapshot = await _request(uri, token);
      if (snapshot == null) {
        return _commit(
          UsageView(
            snapshot: _view.snapshot,
            fetchedAt: _view.fetchedAt,
            failed: true,
          ),
          generation,
        );
      }
      return _commit(
        UsageView(snapshot: snapshot, fetchedAt: _now()),
        generation,
      );
    } on ProviderHttpException {
      // 失败保留上次成功值：界面据此显示「更新失败 · 上次 xx」。
      return _commit(
        UsageView(
          snapshot: _view.snapshot,
          fetchedAt: _view.fetchedAt,
          failed: true,
        ),
        generation,
      );
    }
  }

  UsageView _commit(UsageView next, int generation) {
    if (generation == _generation) _view = next;
    return _view;
  }

  /// 按供应商选端点；未知主机返回 null（不猜、不发凭据）。
  Uri? _endpoint() {
    final base = Uri.tryParse(_config.baseUrl);
    if (base == null || !base.hasAuthority) return null;
    final origin = base.origin;
    if (base.host == 'opencode.ai') {
      return Uri.parse('$origin/zen/go/v1/usage');
    }
    return switch (base.host) {
      'api.deepseek.com' => Uri.parse('$origin/user/balance'),
      'openrouter.ai' => Uri.parse('$origin/api/v1/credits'),
      _ => null,
    };
  }

  /// OpenRouter 账户余额需 Management Key；无权限时回退到 Key 预算。
  Future<UsageSnapshot?> _request(Uri uri, CancelToken token) async {
    if (uri.host == 'openrouter.ai') {
      try {
        final credits = mapOpenRouterCredits(
          await _http.getJson(uri, cancelToken: token),
        );
        if (credits != null) return credits;
      } on ProviderHttpException catch (error) {
        // 只有权限拒绝回退；超时与取消不再发第二个请求。
        if (error.statusCode != 403) rethrow;
      }
      final keyUri = uri.replace(path: '/api/v1/key');
      return mapOpenRouterKey(await _http.getJson(keyUri, cancelToken: token));
    }
    final body = await _http.getJson(uri, cancelToken: token);
    return uri.host == 'api.deepseek.com'
        ? mapDeepSeekBalance(body)
        : mapOpenCodeGoUsage(body);
  }

  // 连接由 ProviderRuntime 独占持有，本服务不重复关闭共享的 HTTP 客户端。
}
