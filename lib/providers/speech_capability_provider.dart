/// 在线语音能力验证的界面状态与动作。
///
/// 结论按非秘密配置身份保存，普通重启后可直接复用；验证期间地址、Key 或模型
/// 变化时，旧回调既不写结论也不改状态。这里不缓存 Key，也不触发任何自动上传。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/recognition_selection.dart';
import '../services/speech/practice_online_transcriber.dart';
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

/// 在线文件转写客户端；业务入口共用同一实例，测试覆盖为假 transport。
final speechTranscriptionClientProvider = Provider<SpeechTranscriptionClient>(
  (ref) => SpeechTranscriptionClient(),
);

/// 某用途能否选用在线：需要 Key、上传告知与该用途自己的能力验证。
///
/// 字幕要求片段时间戳，跟读与复述只需文本；纯文本能力不能把字幕在线列为可选。
/// 界面据此决定是否把在线列为可选方式；三条业务入口在发请求前用
/// [resolvePracticeOnlineAccess] 再确认一次，避免配置已变时静默上传。
final onlinePracticeAvailabilityProvider =
    FutureProvider.family<bool, RecognitionPurpose>((ref, purpose) async {
      final access = await resolvePracticeOnlineAccess(
        ref,
        purpose,
        requiredCapability: purpose == RecognitionPurpose.subtitle
            ? OnlineCapabilityRequirement.segments
            : OnlineCapabilityRequirement.text,
      );
      return access is PracticeOnlineAccessGranted;
    });

/// 在线方式当前不可选的原因；可选用时为 null。
///
/// 同步读取已 watch 的配置与能力状态：验证或配置一变就重算，不另发异步请求，
/// 也不会因自依赖挂起。界面用它直接说明「还缺什么」，而不是把该方式隐藏。
/// 字幕额外要求片段时间戳能力，纯文本模型属于 [PracticeOnlineAccessDenial.capabilityNotSuitable]。
final onlineModeBlockReasonProvider =
    Provider.family<PracticeOnlineAccessDenial?, RecognitionPurpose>((
      ref,
      purpose,
    ) {
      final configuration = ref.watch(speechConfigurationProvider).valueOrNull;
      final config = configuration?.config;
      if (configuration == null || config == null) {
        return PracticeOnlineAccessDenial.missingConfiguration;
      }
      final modelId = config.onlineModelFor(purpose);
      if (modelId.isEmpty) {
        return PracticeOnlineAccessDenial.missingConfiguration;
      }
      // 地址与模型齐备后，缺 Key 是另一件要补的事，不能混成「未配置」。
      if (!configuration.hasApiKey) {
        return PracticeOnlineAccessDenial.missingApiKey;
      }
      final capabilities = ref.watch(speechCapabilityProvider).valueOrNull;
      if (capabilities == null) {
        return PracticeOnlineAccessDenial.capabilityUnverified;
      }
      final capability = capabilities.capabilityFor(
        config: config,
        credentialVersion: configuration.credentialVersion,
        purpose: purpose,
      );
      if (capability == null) {
        return PracticeOnlineAccessDenial.capabilityUnverified;
      }
      final suitable = purpose == RecognitionPurpose.subtitle
          ? capability.segments
          : capability.text;
      return suitable
          ? null
          : PracticeOnlineAccessDenial.capabilityNotSuitable;
    });

/// 在线方式需要的能力等级：练习只需文本，字幕必须有片段时间戳。
enum OnlineCapabilityRequirement { text, segments }

/// 解析某用途在线的准入结果：不具备条件时返回拒绝原因，不发任何请求。
///
/// 三个用途共用一份服务与 Key，但模型与能力验证按用途各自绑定：复述不会因为
/// 跟读或字幕验证过就获得上传许可。
Future<PracticeOnlineAccess> resolvePracticeOnlineAccess(
  Ref ref,
  RecognitionPurpose purpose, {
  OnlineCapabilityRequirement requiredCapability =
      OnlineCapabilityRequirement.text,
}) async {
  final configStore = ref.read(speechConfigStoreProvider);
  final config = await configStore.read();
  final apiKey = await configStore.readApiKey();
  final modelId = config?.onlineModelFor(purpose) ?? '';
  if (config == null || modelId.isEmpty) {
    return const PracticeOnlineAccessDenied(
      PracticeOnlineAccessDenial.missingConfiguration,
    );
  }
  if (apiKey == null) {
    return const PracticeOnlineAccessDenied(
      PracticeOnlineAccessDenial.missingApiKey,
    );
  }
  // 首次向该服务上传用户录音前必须有告知；没有告知就不上传。
  final noticeDone = await ref
      .read(speechCapabilityStoreProvider)
      .hasUploadNotice(config.baseUrl);
  if (!noticeDone) {
    return const PracticeOnlineAccessDenied(
      PracticeOnlineAccessDenial.uploadNoticeMissing,
    );
  }
  final credentialVersion = await configStore.readCredentialVersion();
  final capability = (await ref.read(speechCapabilityProvider.future))
      .capabilityFor(
        config: config,
        credentialVersion: credentialVersion,
        purpose: purpose,
      );
  if (capability == null) {
    return const PracticeOnlineAccessDenied(
      PracticeOnlineAccessDenial.capabilityUnverified,
    );
  }
  // 已验证但能力不满足该用途：字幕必须有片段时间戳，不能反复叫人去验证。
  if (requiredCapability == OnlineCapabilityRequirement.text) {
    if (!capability.text) {
      return const PracticeOnlineAccessDenied(
        PracticeOnlineAccessDenial.capabilityNotSuitable,
      );
    }
  } else if (!capability.segments) {
    return const PracticeOnlineAccessDenied(
      PracticeOnlineAccessDenial.capabilityNotSuitable,
    );
  }
  return PracticeOnlineAccessGranted(
    config: config,
    apiKey: apiKey,
    modelId: modelId,
    // 分块进度只在同一服务、地址、模型与凭据版本下可以续试。
    identity: SpeechCapability.identityFor(
      kind: config.kind,
      baseUrl: config.baseUrl,
      modelId: modelId,
      credentialVersion: credentialVersion,
    ),
  );
}

/// 当前能力验证状态。
final speechCapabilityProvider =
    AsyncNotifierProvider<SpeechCapabilityNotifier, SpeechCapabilityState>(
      SpeechCapabilityNotifier.new,
    );

/// 当前语音配置是否已通过字幕（片段时间戳）能力验证。
///
/// 字幕在线方式的唯一准入依据：没保存完整配置、没有 Key，或结论不属于当前
/// 非秘密配置身份时为 false。配置变化后旧结论自然不再匹配。
final onlineSubtitleAvailableProvider = Provider<bool>((ref) {
  final configuration = ref.watch(speechConfigurationProvider).valueOrNull;
  final config = configuration?.config;
  final capabilities = ref.watch(speechCapabilityProvider).valueOrNull;
  if (configuration == null ||
      !configuration.isConfigured ||
      config == null ||
      capabilities == null) {
    return false;
  }
  final capability = capabilities.capabilityFor(
    config: config,
    credentialVersion: configuration.credentialVersion,
    purpose: RecognitionPurpose.subtitle,
  );
  return capability?.segments ?? false;
});

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
