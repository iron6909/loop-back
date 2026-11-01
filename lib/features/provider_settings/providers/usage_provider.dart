/// 当前供应商的用量状态；切换配置会取消查询并丢弃旧结果。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/provider_configuration_provider.dart';
import '../../../services/provider/usage_query_service.dart';

class UsageQueryNotifier extends AsyncNotifier<UsageView> {
  UsageQueryService? _service;
  int _generation = 0;

  @override
  Future<UsageView> build() async {
    final generation = ++_generation;
    ref.onDispose(() {
      _generation++;
      _service?.invalidate();
    });
    final runtime = await ref.watch(providerConfigurationProvider.future);
    if (generation != _generation || runtime == null) {
      return const UsageView();
    }
    final service = UsageQueryService(
      http: runtime.http,
      config: runtime.config,
    );
    _service = service;
    return service.refresh();
  }

  /// 刷新时保留旧数据；并发请求由服务合并。
  Future<void> refresh() async {
    final service = _service;
    if (service == null) return;
    final generation = _generation;
    state = const AsyncLoading<UsageView>().copyWithPrevious(state);
    final view = await service.refresh(force: true);
    if (generation == _generation) state = AsyncData(view);
  }
}

final usageQueryProvider = AsyncNotifierProvider<UsageQueryNotifier, UsageView>(
  UsageQueryNotifier.new,
);
