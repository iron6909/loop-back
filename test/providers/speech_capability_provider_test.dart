/// 能力验证状态测试。
///
/// 覆盖结论落库、凭据变化后旧回调失效、失败不伪造已验证，以及模型目录刷新失败
/// 不阻止手填模型。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:loop_back/models/recognition_selection.dart';
import 'package:loop_back/providers/speech_capability_provider.dart';
import 'package:loop_back/providers/speech_configuration_provider.dart';
import 'package:loop_back/services/speech/practice_online_transcriber.dart';
import 'package:loop_back/services/speech/speech_capability.dart';
import 'package:loop_back/services/speech/speech_capability_probe.dart';
import 'package:loop_back/services/speech/speech_config.dart';
import 'package:loop_back/services/speech/speech_config_store.dart';
import 'package:loop_back/services/speech/speech_model_catalog.dart';
import 'package:loop_back/services/speech/speech_transcription_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只保存在内存里的在线语音配置替身，可模拟保存过程中凭据版本变化。
class _InMemorySpeechConfigStore extends SpeechConfigStore {
  _InMemorySpeechConfigStore({this.config, this.apiKey})
    : credentialVersion = 'credential-a';

  SpeechConfig? config;
  String? apiKey;
  String credentialVersion;

  @override
  Future<SpeechConfig?> read() async => config;

  @override
  Future<String?> readApiKey() async => apiKey;

  @override
  Future<String?> readCredentialVersion() async => credentialVersion;

  @override
  Future<void> save(SpeechConfig value, {String? apiKey}) async {
    config = value;
    if (apiKey != null) this.apiKey = apiKey;
  }
}

/// 只保存在内存里的能力记录替身；[events] 记录告知与请求的先后顺序。
class _InMemoryCapabilityStore extends SpeechCapabilityStore {
  final Map<String, SpeechCapability> records = {};
  final List<String> events = [];

  @override
  Future<Map<String, SpeechCapability>> readAll() async => Map.of(records);

  @override
  Future<SpeechCapability?> read(String identity) async => records[identity];

  @override
  Future<void> save(SpeechCapability capability) async {
    records[capability.identity] = capability;
  }

  @override
  Future<void> clear() async => records.clear();

  @override
  Future<bool> hasUploadNotice(String baseUrl) async => true;

  @override
  Future<void> rememberUploadNotice(String baseUrl) async {
    events.add('notice');
  }
}

/// 可控的能力验证替身：用 Completer 控制回调时机，不用任意延时。
class _ControllableProbe implements SpeechCapabilityProbe {
  _ControllableProbe(this.events);

  final List<String> events;
  final List<Completer<SpeechCapability>> calls = [];
  Object? failure;
  int runCount = 0;
  String? modelId;

  @override
  Future<SpeechCapability> run({
    required SpeechConfig config,
    required String apiKey,
    required String modelId,
    required String? credentialVersion,
    CancelToken? cancelToken,
  }) {
    runCount++;
    events.add('probe');
    this.modelId = modelId;
    if (failure case final error?) return Future.error(error);
    final completer = Completer<SpeechCapability>();
    calls.add(completer);
    return completer.future;
  }
}

/// 目录刷新替身。
class _FakeCatalog implements SpeechModelCatalogClient {
  List<String> models = const [];
  Object? failure;
  int callCount = 0;

  @override
  Future<List<String>> fetchTranscriptionModels({
    required SpeechConfig config,
    required String apiKey,
    CancelToken? cancelToken,
  }) async {
    callCount++;
    if (failure case final error?) throw error;
    return models;
  }
}

void main() {
  const openRouterConfig = SpeechConfig(
    kind: SpeechProviderKind.openrouter,
    baseUrl: 'https://openrouter.ai/api/v1',
    onlineModels: {
      RecognitionPurpose.subtitle: 'openai/whisper-large-v3',
      RecognitionPurpose.shadowing: 'openai/whisper-large-v3',
    },
  );

  late _InMemorySpeechConfigStore speechStore;
  late _InMemoryCapabilityStore capabilityStore;
  late _ControllableProbe probe;
  late _FakeCatalog catalog;

  SpeechCapability capability({required String credentialVersion}) =>
      SpeechCapability(
        identity: SpeechCapability.identityFor(
          kind: SpeechProviderKind.openrouter,
          baseUrl: 'https://openrouter.ai/api/v1',
          modelId: 'openai/whisper-large-v3',
          credentialVersion: credentialVersion,
        ),
        text: true,
        segments: true,
        wordTimestamps: true,
        validatedAt: DateTime.utc(2026, 11, 7, 12),
      );

  ProviderContainer createContainer({String? apiKey = 'sk-speech-test'}) {
    speechStore = _InMemorySpeechConfigStore(
      config: openRouterConfig,
      apiKey: apiKey,
    );
    capabilityStore = _InMemoryCapabilityStore();
    probe = _ControllableProbe(capabilityStore.events);
    catalog = _FakeCatalog();
    final container = ProviderContainer(
      overrides: [
        speechConfigStoreProvider.overrideWithValue(speechStore),
        speechCapabilityStoreProvider.overrideWithValue(capabilityStore),
        speechCapabilityProbeProvider.overrideWithValue(probe),
        speechModelCatalogClientProvider.overrideWithValue(catalog),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('同一配置身份在普通重启后可直接复用结论', () async {
    final container = createContainer();
    capabilityStore.records[capability(
      credentialVersion: 'credential-a',
    ).identity] = capability(
      credentialVersion: 'credential-a',
    );

    final state = await container.read(speechCapabilityProvider.future);

    expect(
      state
          .capabilityFor(
            config: openRouterConfig,
            credentialVersion: 'credential-a',
            purpose: RecognitionPurpose.subtitle,
          )
          ?.segments,
      isTrue,
    );
  });

  test('验证成功后保存结论并可被三个用途共用', () async {
    final container = createContainer();
    final notifier = container.read(speechCapabilityProvider.notifier);
    await container.read(speechCapabilityProvider.future);

    final pending = notifier.test(RecognitionPurpose.subtitle);
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(speechCapabilityProvider).valueOrNull?.testingPurpose,
      RecognitionPurpose.subtitle,
    );
    probe.calls.single.complete(capability(credentialVersion: 'credential-a'));
    await pending;

    final state = container.read(speechCapabilityProvider).valueOrNull;
    expect(probe.modelId, 'openai/whisper-large-v3');
    expect(capabilityStore.records, hasLength(1));
    expect(state?.testingPurpose, isNull);
    expect(
      state
          ?.capabilityFor(
            config: openRouterConfig,
            credentialVersion: 'credential-a',
            purpose: RecognitionPurpose.shadowing,
          )
          ?.segments,
      isTrue,
    );
  });

  test('验证期间配置变化时旧回调不生效', () async {
    final container = createContainer();
    final notifier = container.read(speechCapabilityProvider.notifier);
    await container.read(speechCapabilityProvider.future);

    final pending = notifier.test(RecognitionPurpose.subtitle);
    await Future<void>.delayed(Duration.zero);
    // 用户换 Key：凭据版本变化，旧测试的回调必须作废。
    speechStore.credentialVersion = 'credential-b';
    await container.read(speechConfigurationProvider.notifier).reload();
    probe.calls.single.complete(capability(credentialVersion: 'credential-a'));
    await pending;

    expect(capabilityStore.records, isEmpty);
    final state = container.read(speechCapabilityProvider).valueOrNull;
    expect(
      state?.capabilityFor(
        config: openRouterConfig,
        credentialVersion: 'credential-b',
        purpose: RecognitionPurpose.subtitle,
      ),
      isNull,
    );
  });

  test('首次验证先登记上传告知，再发请求', () async {
    final container = createContainer();
    final notifier = container.read(speechCapabilityProvider.notifier);
    await container.read(speechCapabilityProvider.future);

    final pending = notifier.test(RecognitionPurpose.subtitle);
    await Future<void>.delayed(Duration.zero);

    expect(capabilityStore.events, ['notice', 'probe']);
    probe.calls.single.complete(capability(credentialVersion: 'credential-a'));
    await pending;
  });

  test('缺 Key 时不发请求并报鉴权失败', () async {
    final container = createContainer(apiKey: null);
    final notifier = container.read(speechCapabilityProvider.notifier);
    await container.read(speechCapabilityProvider.future);

    await expectLater(
      notifier.test(RecognitionPurpose.subtitle),
      throwsA(
        isA<SpeechTranscriptionException>().having(
          (error) => error.kind,
          'kind',
          SpeechTranscriptionErrorKind.unauthorized,
        ),
      ),
    );
    expect(probe.runCount, 0);
  });

  test('验证失败不保存结论，状态回到未验证', () async {
    final container = createContainer();
    final notifier = container.read(speechCapabilityProvider.notifier);
    await container.read(speechCapabilityProvider.future);
    probe.failure = const SpeechTranscriptionException(
      SpeechTranscriptionErrorKind.insufficientBalance,
    );

    await expectLater(
      notifier.test(RecognitionPurpose.subtitle),
      throwsA(isA<SpeechTranscriptionException>()),
    );

    expect(capabilityStore.records, isEmpty);
    expect(
      container.read(speechCapabilityProvider).valueOrNull?.testingPurpose,
      isNull,
    );
  });

  test('刷新目录返回模型列表；失败直接抛出，不影响手填', () async {
    final container = createContainer();
    final notifier = container.read(speechCapabilityProvider.notifier);
    await container.read(speechCapabilityProvider.future);
    catalog.models = const ['openai/whisper-large-v3'];

    expect(await notifier.refreshModels(), ['openai/whisper-large-v3']);

    catalog.failure = const SpeechTranscriptionException(
      SpeechTranscriptionErrorKind.network,
    );
    await expectLater(
      notifier.refreshModels(),
      throwsA(isA<SpeechTranscriptionException>()),
    );
    expect(catalog.callCount, 2);
  });

  test('验证成功后在线可用性立即重算，不需要重启', () async {
    final container = createContainer();
    await container.read(speechCapabilityProvider.future);
    await container.read(speechConfigurationProvider.future);

    // 验证前：跟读与字幕都因未验证被阻断。
    expect(
      container.read(
        onlineModeBlockReasonProvider(RecognitionPurpose.shadowing),
      ),
      PracticeOnlineAccessDenial.capabilityUnverified,
    );

    // 验证时用户已确认告知（与真实流程一致：告知记录在验证里）。
    final notifier = container.read(speechCapabilityProvider.notifier);
    final pending = notifier.test(RecognitionPurpose.shadowing);
    await Future<void>.delayed(Duration.zero);
    probe.calls.single.complete(capability(credentialVersion: 'credential-a'));
    await pending;

    // 验证结论一变，可用性与原因必须重算，否则用户验证完仍是灰的。
    expect(
      container.read(
        onlineModeBlockReasonProvider(RecognitionPurpose.shadowing),
      ),
      isNull,
    );
    expect(
      await container.read(
        onlinePracticeAvailabilityProvider(RecognitionPurpose.shadowing).future,
      ),
      isTrue,
    );
  });

  test('有服务地址但缺 Key 时说明缺的是 Key，而不是未配置', () async {
    final container = createContainer(apiKey: null);
    await container.read(speechConfigurationProvider.future);

    expect(
      container.read(
        onlineModeBlockReasonProvider(RecognitionPurpose.shadowing),
      ),
      PracticeOnlineAccessDenial.missingApiKey,
    );
    expect(
      await container.read(
        onlinePracticeAvailabilityProvider(RecognitionPurpose.shadowing).future,
      ),
      isFalse,
    );
  });

  test('有服务地址和 Key，但该用途没有在线模型时说明缺模型', () async {
    final container = createContainer();
    speechStore.config = const SpeechConfig(
      kind: SpeechProviderKind.openrouter,
      baseUrl: 'https://openrouter.ai/api/v1',
      onlineModels: {
        RecognitionPurpose.subtitle: 'openai/whisper-large-v3',
      },
    );
    await container.read(speechConfigurationProvider.future);

    expect(
      container.read(
        onlineModeBlockReasonProvider(RecognitionPurpose.shadowing),
      ),
      PracticeOnlineAccessDenial.missingOnlineModel,
    );
    expect(
      await container.read(
        onlinePracticeAvailabilityProvider(RecognitionPurpose.shadowing).future,
      ),
      isFalse,
    );
  });

  test('没有保存服务地址时说明未配置，而不是缺 Key', () async {
    final container = createContainer();
    speechStore.config = null;
    await container.read(speechConfigurationProvider.future);

    expect(
      container.read(
        onlineModeBlockReasonProvider(RecognitionPurpose.shadowing),
      ),
      PracticeOnlineAccessDenial.missingConfiguration,
    );
  });

  test('已验证但只返回文本的模型不能用于字幕，原因不是「去验证」', () async {
    final container = createContainer();
    final textOnly = SpeechCapability(
      identity: capability(credentialVersion: 'credential-a').identity,
      text: true,
      segments: false,
      wordTimestamps: false,
      validatedAt: DateTime.utc(2026, 11, 7, 12),
    );
    // 让能力状态读到这条记录（与真实界面一致：配置先加载完成）。
    await container.read(speechConfigurationProvider.future);
    capabilityStore.records[textOnly.identity] = textOnly;
    container.invalidate(speechCapabilityProvider);
    await container.read(speechCapabilityProvider.future);

    expect(
      container.read(
        onlineModeBlockReasonProvider(RecognitionPurpose.subtitle),
      ),
      PracticeOnlineAccessDenial.capabilityNotSuitable,
    );
    // 练习只需要文本，同一结论下跟读仍可用。
    expect(
      container.read(
        onlineModeBlockReasonProvider(RecognitionPurpose.shadowing),
      ),
      isNull,
    );
    expect(
      await container.read(
        onlinePracticeAvailabilityProvider(RecognitionPurpose.subtitle).future,
      ),
      isFalse,
      reason: '异步可用性同样要求片段时间戳，纯文本能力不能启用字幕在线',
    );
    expect(
      await container.read(
        onlinePracticeAvailabilityProvider(RecognitionPurpose.shadowing).future,
      ),
      isTrue,
    );
  });
}
