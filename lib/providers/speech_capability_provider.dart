/// 在线语音能力验证的界面状态与动作。
///
/// 结论按非秘密配置身份保存，普通重启后可直接复用；验证期间地址、Key 或模型
/// 变化时，旧回调既不写结论也不改状态。这里不缓存 Key，也不触发任何自动上传。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/recognition_selection.dart';
import '../services/speech/speech_capability.dart';
import '../services/speech/speech_capability_probe.dart';
import '../services/speech/speech_config.dart';
import '../services/speech/speech_model_catalog.dart';
import '../services/speech/speech_transcription_client.dart';
import 'speech_configuration_provider.dart';

/// 能力验证状态：已有结论 + 正在验证的用途。
class SpeechCapabilityState {
  const SpeechCapabilityState({
    this.capabilities = const {},
    this.testingPurpose,
  });

  /// 按非秘密配置身份索引的结论。
  final Map<String, SpeechCapability> capabilities;

  /// 正在验证的用途；null 表示当前没有验证请求。
  final RecognitionPurpose? testingPurpose;

  /// 当前配置与用途的结论；配置变化后自然为 null（未验证）。
  SpeechCapability? capabilityFor({
    required SpeechConfig config,
    required String? credentialVersion,
    required RecognitionPurpose purpose,
  }) {
    final modelId = config.onlineModelFor(purpose);
    if (modelId.isEmpty) return null;
    return capabilities[SpeechCapability.identityFor(
      kind: config.kind,
      baseUrl: config.baseUrl,
      modelId: modelId,
      credentialVersion: credentialVersion,
    )];
  }
}

/// 能力记录与本机上传告知；测试覆盖此 provider 注入受控存储。
final speechCapabilityStoreProvider = Provider<SpeechCapabilityStore>(
  (ref) => SpeechCapabilityStore(),
);

/// 真实能力验证；测试覆盖为受控替身，避免付费请求。
final speechCapabilityProbeProvider = Provider<SpeechCapabilityProbe>(
  (ref) => SpeechCapabilityProbe(),
);

/// OpenRouter 专用模型目录；失败只影响列表，不影响手填模型。
final speechModelCatalogClientProvider = Provider<SpeechModelCatalogClient>(
  (ref) => SpeechModelCatalogClient(),
);

/// 当前能力验证状态。
final speechCapabilityProvider =
    AsyncNotifierProvider<SpeechCapabilityNotifier, SpeechCapabilityState>(
      SpeechCapabilityNotifier.new,
    );

/// 触发一次真实能力验证并维护结论。
class SpeechCapabilityNotifier extends AsyncNotifier<SpeechCapabilityState> {
  int _generation = 0;

  @override
  Future<SpeechCapabilityState> build() async => SpeechCapabilityState(
    capabilities: await ref.read(speechCapabilityStoreProvider).readAll(),
  );

  SpeechCapabilityState get _current =>
      state.valueOrNull ?? const SpeechCapabilityState();

  /// 首次向该服务上传样本前是否需要告知。
  Future<bool> needsUploadNotice() async {
    final config = await ref.read(speechConfigStoreProvider).read();
    if (config == null) return true;
    return !await ref
        .read(speechCapabilityStoreProvider)
        .hasUploadNotice(config.baseUrl);
  }

  /// 对该用途选中的在线模型做一次验证。
  ///
  /// 只发一次请求，不重试、不改参数重发。失败原样抛给界面显示，不保存结论。
  Future<void> test(RecognitionPurpose purpose) async {
    final configStore = ref.read(speechConfigStoreProvider);
    final config = await configStore.read();
    final modelId = config?.onlineModelFor(purpose) ?? '';
    if (config == null || modelId.isEmpty) {
      throw const SpeechTranscriptionException(
        SpeechTranscriptionErrorKind.invalidRequest,
      );
    }
    final apiKey = await configStore.readApiKey();
    if (apiKey == null) {
      throw const SpeechTranscriptionException(
        SpeechTranscriptionErrorKind.unauthorized,
      );
    }
    final credentialVersion = await configStore.readCredentialVersion();
    final identity = SpeechCapability.identityFor(
      kind: config.kind,
      baseUrl: config.baseUrl,
      modelId: modelId,
      credentialVersion: credentialVersion,
    );
    final generation = ++_generation;
    state = AsyncData(
      SpeechCapabilityState(
        capabilities: _current.capabilities,
        testingPurpose: purpose,
      ),
    );
    try {
      // 用户已在界面上确认上传与可能收费；先记录再上传，失败也不重复告知。
      await ref
          .read(speechCapabilityStoreProvider)
          .rememberUploadNotice(config.baseUrl);
      final capability = await ref
          .read(speechCapabilityProbeProvider)
          .run(
            config: config,
            apiKey: apiKey,
            modelId: modelId,
            credentialVersion: credentialVersion,
          );
      if (generation != _generation) return;
      // 验证期间改了地址、Key 或模型：结论属于旧配置，丢弃。
      if (await _currentIdentity(purpose) != identity) return;
      await ref.read(speechCapabilityStoreProvider).save(capability);
      if (generation != _generation) return;
      state = AsyncData(
        SpeechCapabilityState(
          capabilities: {..._current.capabilities, identity: capability},
        ),
      );
    } finally {
      if (generation == _generation && _current.testingPurpose != null) {
        state = AsyncData(
          SpeechCapabilityState(capabilities: _current.capabilities),
        );
      }
    }
  }

  /// 刷新 OpenRouter 的专用转写目录；失败由界面提示，手填模型始终可用。
  Future<List<String>> refreshModels() async {
    final configStore = ref.read(speechConfigStoreProvider);
    final config = await configStore.read();
    final apiKey = await configStore.readApiKey();
    if (config == null) {
      throw const SpeechTranscriptionException(
        SpeechTranscriptionErrorKind.invalidRequest,
      );
    }
    if (apiKey == null) {
      throw const SpeechTranscriptionException(
        SpeechTranscriptionErrorKind.unauthorized,
      );
    }
    return ref
        .read(speechModelCatalogClientProvider)
        .fetchTranscriptionModels(config: config, apiKey: apiKey);
  }

  /// 当前配置与用途的身份；与验证开始时不一致即表示配置已变化。
  Future<String?> _currentIdentity(RecognitionPurpose purpose) async {
    final configStore = ref.read(speechConfigStoreProvider);
    final config = await configStore.read();
    if (config == null) return null;
    final modelId = config.onlineModelFor(purpose);
    if (modelId.isEmpty) return null;
    return SpeechCapability.identityFor(
      kind: config.kind,
      baseUrl: config.baseUrl,
      modelId: modelId,
      credentialVersion: await configStore.readCredentialVersion(),
    );
  }
}
