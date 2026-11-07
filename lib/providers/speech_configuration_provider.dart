/// 在线语音配置的生命周期：把「普通配置 + 是否已有 Key + 凭据版本」变成界面可读状态。
///
/// 与文字 AI 的 `ProviderConfigurationNotifier` 独立：改语音地址或清除语音 Key
/// 不影响翻译、讲解和聊天，反之亦然。保存串行化，晚到的旧回调不能覆盖新配置。
/// 本切片不构造转写客户端，保存配置本身不发出任何网络请求。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/speech/speech_config.dart';
import '../services/speech/speech_config_store.dart';

/// 在线语音配置状态快照。
///
/// 能力验证由后续切片绑定 [credentialVersion]；这里只区分未配置与已保存未验证，
/// 尚未验证的配置不能启用在线识别。
class SpeechConfigurationState {
  const SpeechConfigurationState({
    this.config,
    this.hasApiKey = false,
    this.credentialVersion,
  });

  /// 普通配置；null 表示尚未保存过在线语音服务。
  final SpeechConfig? config;

  /// 安全存储里是否已有 Key。
  final bool hasApiKey;

  /// 非秘密的凭据版本；Key 变化或恢复后换成新令牌，旧能力验证据此失效。
  final String? credentialVersion;

  /// 服务地址与 Key 齐备，才可能启用在线识别（仍需适用能力验证）。
  bool get isConfigured => config != null && hasApiKey;
}

/// 在线语音配置与凭据的持久化入口；测试覆盖此 provider 注入受控安全存储。
final speechConfigStoreProvider = Provider<SpeechConfigStore>(
  (ref) => SpeechConfigStore(),
);

/// 当前在线语音配置状态。
final speechConfigurationProvider =
    AsyncNotifierProvider<
      SpeechConfigurationNotifier,
      SpeechConfigurationState
    >(SpeechConfigurationNotifier.new);

/// 读取与串行写入在线语音配置，并丢弃晚到的旧回调。
class SpeechConfigurationNotifier
    extends AsyncNotifier<SpeechConfigurationState> {
  int _generation = 0;

  @override
  Future<SpeechConfigurationState> build() async => _read();

  /// 保存配置；[apiKey] 为 null 表示保留现有 Key。
  Future<void> save(SpeechConfig config, {String? apiKey}) => _apply(
    () => ref.read(speechConfigStoreProvider).save(config, apiKey: apiKey),
  );

  /// 删除 Key，保留配置；旧能力验证随之失效。
  Future<void> clearKey() =>
      _apply(ref.read(speechConfigStoreProvider).clearKey);

  /// 从存储重新读取（例如备份恢复后）。
  Future<void> reload() => _apply(() async {});

  Future<SpeechConfigurationState> _read() async {
    final store = ref.read(speechConfigStoreProvider);
    final config = await store.read();
    final apiKey = await store.readApiKey();
    final credentialVersion = await store.readCredentialVersion();
    return SpeechConfigurationState(
      config: config,
      hasApiKey: apiKey != null,
      credentialVersion: credentialVersion,
    );
  }

  /// 动作成功后重读存储；失败原样抛给调用方显示，不伪造已保存状态。
  ///
  /// 每次动作带上 generation：晚到的旧回调即使成功也不改写更新的状态。
  Future<void> _apply(Future<void> Function() action) async {
    final generation = ++_generation;
    await _awaitInitialRead();
    await action();
    if (generation != _generation) return;
    state = AsyncValue.data(await _read());
  }

  /// 初始读取可能仍在进行；等它结束，避免它完成后用旧值覆盖本次写入。
  Future<void> _awaitInitialRead() async {
    try {
      await future;
    } catch (_) {
      // 初始读取失败不阻止重试保存；成功后状态会重新读取。
    }
  }
}
