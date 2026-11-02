/// 供应商配置的生命周期与依赖装配
///
/// 唯一职责：把「已保存的配置 + 安全存储里的 Key」变成可直接使用的客户端，并在
/// 配置变化时立刻作废旧客户端。作废是**先销毁再重建**：换地址或换 Key 后，旧配置的
/// 在途请求不得继续把结果写回界面或缓存（spec REQ-11）。
///
/// 未配置时 [ProviderConfigurationNotifier] 的值为 null，上层据此显示未配置状态且
/// 不发出任何请求（spec REQ-1），而不是发一个空 Key 的请求。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/providers.dart';
import '../services/provider/provider_config.dart';
import '../services/provider/provider_config_store.dart';
import '../services/provider/provider_http_client.dart';
import '../services/provider/structured_ai_client.dart';

export '../services/provider/provider_config.dart'
    show ProviderNotConfiguredException;

/// 配置与凭据的持久化入口。
final providerConfigStoreProvider = Provider<ProviderConfigStore>(
  (ref) => ProviderConfigStore(),
);

/// 供应商 Dio 的构造工厂；测试覆盖此 provider 注入假 adapter。
///
/// 与 `backendDio` 完全独立：不挂 Supabase token、平台/渠道头、权益拦截器，
/// 也不经区域路由（spec「模块职责」）。
final providerDioFactoryProvider = Provider<Dio Function()>((ref) => Dio.new);

/// 一次配置生效期间可复用的客户端集合。
///
/// 与配置同生命周期：配置一变，旧实例整体作废，不做局部替换。
class ProviderRuntime {
  const ProviderRuntime({
    required this.config,
    required this.apiKey,
    required this.http,
    required this.structured,
  });

  final ProviderConfig config;

  /// 仅用于构造请求头；不写日志、不进缓存键（spec REQ-3、REQ-10）。
  final String apiKey;

  final ProviderHttpClient http;
  final StructuredAiClient structured;

  /// 释放连接与在途请求。
  void dispose() {
    structured.dispose();
  }
}

/// 当前生效的供应商运行时；null 表示未配置。
class ProviderConfigurationNotifier extends AsyncNotifier<ProviderRuntime?> {
  @override
  Future<ProviderRuntime?> build() async {
    final store = ref.watch(providerConfigStoreProvider);
    final config = await store.read();
    if (config == null) return null;
    final apiKey = await store.readApiKey();
    if (apiKey == null) return null;
    final runtime = _assemble(config, apiKey);
    ref.onDispose(runtime.dispose);
    return runtime;
  }

  /// 保存配置；[apiKey] 为 null 表示保留现有 Key。
  ///
  /// 先作废旧运行时再落盘：即使写入失败，界面也不会继续用旧地址发请求。
  Future<void> save(ProviderConfig config, {String? apiKey}) async {
    _disposeCurrent();
    state = const AsyncValue.loading();
    try {
      await ref.read(providerConfigStoreProvider).save(config, apiKey: apiKey);
      await _rebuild();
    } catch (error, stack) {
      state = AsyncError(error, stack);
      rethrow;
    }
  }

  /// 删除 Key，回到未配置状态。
  Future<void> clearKey() async {
    _disposeCurrent();
    state = const AsyncValue.loading();
    try {
      await ref.read(providerConfigStoreProvider).clearKey();
      await _rebuild();
    } catch (error, stack) {
      state = AsyncError(error, stack);
      rethrow;
    }
  }

  /// 从存储重新读取（例如备份恢复后）。
  Future<void> reload() async {
    _disposeCurrent();
    state = const AsyncValue.loading();
    await _rebuild();
  }

  Future<void> _rebuild() async {
    ref.invalidateSelf();
    await future;
  }

  void _disposeCurrent() {
    if (state.valueOrNull case final runtime?) runtime.dispose();
  }

  /// 缓存读写直接对接既有 DAO：缓存写入只发生在结构化客户端一处。
  ProviderRuntime _assemble(ProviderConfig config, String apiKey) {
    final http = ProviderHttpClient(
      config: config,
      apiKey: apiKey,
      dio: ref.read(providerDioFactoryProvider)(),
    );
    // 运行时持有缓存 DAO，切库时连同旧请求和内存结果一起作废。
    final dao = ref.watch(sentenceAiCacheDaoProvider);
    return ProviderRuntime(
      config: config,
      apiKey: apiKey,
      http: http,
      structured: StructuredAiClient(
        http: http,
        config: config,
        readCache: dao.getByHash,
        writeCache:
            ({
              required String type,
              required String textHash,
              required String payload,
            }) => dao.upsert(textHash, type, payload),
      ),
    );
  }
}

/// 当前配置的运行时。
final providerConfigurationProvider =
    AsyncNotifierProvider<ProviderConfigurationNotifier, ProviderRuntime?>(
      ProviderConfigurationNotifier.new,
    );

/// 不含 Key 的已保存配置；即使 Key 尚未填写，设置页仍能继续编辑。
final savedProviderConfigProvider = FutureProvider<ProviderConfig?>((ref) {
  ref.watch(providerConfigurationProvider);
  return ref.read(providerConfigStoreProvider).read();
});

/// AI 服务是否可用：默认取决于是否已保存供应商配置。
///
/// 界面据此决定是否自动发起请求；测试可覆盖为 true 以验证自动加载路径，
/// 无需构造真实供应商运行时。
final aiServiceAvailableProvider = Provider<bool>(
  (ref) => ref.watch(providerConfigurationProvider).valueOrNull != null,
);
