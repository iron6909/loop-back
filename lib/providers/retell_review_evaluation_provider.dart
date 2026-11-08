/// 复述评估：同 attempt 转写优先，转写成功后才请求独立文字服务。
///
/// 本机与在线两条转写路径都按复述自己的识别选择执行；识别阶段失败不进入评估，
/// 两类错误（语音 / 文字 AI）在状态里分开保存，界面分别呈现。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../features/subscription/models/ai_quota_rejection.dart';
import '../models/retell_review_evaluation.dart';
import '../models/retell_review_sample.dart';
import '../services/app_logger.dart';
import '../services/asr/offline_asr_engine.dart';
import '../services/retell_transcriber.dart';
import '../services/sentence_ai_api_client.dart';
import '../services/speech/practice_online_transcriber.dart';
import '../services/speech/speech_config.dart';
import '../services/speech/speech_transcription_client.dart';
import 'asr_engine_provider.dart';
import 'local_transcription_task_provider.dart';
import 'provider_configuration_provider.dart';
import 'recognition_settings_provider.dart';
import 'speech_capability_provider.dart';
import 'speech_configuration_provider.dart';
import '../models/recognition_selection.dart';

enum RetellReviewEvaluationPhase { idle, loading, streaming, completed, failed }

/// 本次评估经过的在线语音：实际模型、接收音频的服务与供应商报告的费用。
class RetellOnlineSpeech {
  const RetellOnlineSpeech({
    required this.modelId,
    required this.serviceHost,
    this.reportedCost,
  });

  /// 复述用途实际使用的在线模型。
  final String modelId;

  /// 接收音频的服务主机名，不含协议与路径。
  final String serviceHost;

  /// 供应商报告的本次费用；null 表示未知，界面不能显示为免费。
  final double? reportedCost;
}

class RetellReviewEvaluationState {
  const RetellReviewEvaluationState({this.attemptKey,
    this.phase = RetellReviewEvaluationPhase.idle, this.evaluation, this.errorCode,
    this.speechError, this.onlineSpeech,
    this.quotaReason = AiQuotaRejectionReason.exhausted});
  final String? attemptKey;
  final RetellReviewEvaluationPhase phase;
  final RetellReviewEvaluation? evaluation;

  /// 文字 AI 阶段的失败分类，交给 [retellReviewErrorMessage] 显示。
  final String? errorCode;

  /// 转写阶段的失败原因（在线准入、录音边界或转写错误）；与 [errorCode] 分开，
  /// 避免把语音失败当成文字 AI 失败，也避免把技术失败当成学习者的表达错误。
  final Object? speechError;

  /// 本次评估经过的在线语音；null 表示没有走在线转写。
  final RetellOnlineSpeech? onlineSpeech;

  // 旧页面参数保留，生产逻辑不再产生会员配额错误。
  final AiQuotaRejectionReason quotaReason;
  bool get hasCachedResult => phase == RetellReviewEvaluationPhase.completed && evaluation != null;
}

/// 独立本机转写入口；按复述自己的识别选择执行，不上传录音。
///
/// 复述不再借用字幕模型：模型来自复述用途的本机档位，与字幕、跟读各自独立。
final retellTranscriptProvider = Provider<Future<String?> Function(String)>((ref) {
  return RetellTranscriber(
    engineFactory: ref.read(localTranscriptionEngineFactoryProvider),
    transcode: ref.read(localTranscriptionTranscodeServiceProvider),
    configuration: () async {
      final model = ref.read(
        recognitionLocalModelProvider(RecognitionPurpose.retell),
      );
      final manager = ref.read(asrModelManagerProvider);
      if (!await manager.isModelDownloaded(model.id)) {
        throw StateError('请先下载英语识别模型');
      }
      return AsrModelConfig(model: model, modelDir: await manager.modelDir(model.id),
        numThreads: AsrModelConfig.recommendedThreads());
    },
  ).transcribe;
});

final retellReviewEvaluationProvider = NotifierProvider<
  RetellReviewEvaluationController, RetellReviewEvaluationState>(
    RetellReviewEvaluationController.new);

/// 复述在线的单块转写结果。
class RetellOnlineTranscript {
  const RetellOnlineTranscript({
    required this.text,
    required this.identity,
    required this.modelId,
    required this.serviceHost,
    this.reportedCost,
  });

  final String text;

  /// 实际识别身份（服务类型、根地址与该用途的在线模型），用来判断能否复用。
  final String identity;

  final String modelId;
  final String serviceHost;

  /// 供应商报告的本次费用；null 表示未知，不按免费处理。
  final double? reportedCost;
}

/// 复述在线的单块转写入口：准入 → 录音边界检查 → 一次上传。
///
/// 与 [retellTranscriptProvider]（本机）并列，按复述自己的识别选择执行：模型来自
/// 复述用途的在线配置，不借助字幕或跟读的选择；不做参数变换、不重试、不换服务。
/// 失败原样抛出分类异常（准入拒绝 / 录音不满足单块条件 / 转写错误），由调用方
/// 决定如何呈现。
final retellOnlineTranscriptProvider =
    Provider<
      Future<RetellOnlineTranscript> Function(
        String filePath, {
        CancelToken? cancelToken,
      })
    >((ref) {
      final client = ref.read(speechTranscriptionClientProvider);
      return (filePath, {CancelToken? cancelToken}) async {
        final access = await resolvePracticeOnlineAccess(
          ref,
          RecognitionPurpose.retell,
        );
        switch (access) {
          case PracticeOnlineAccessDenied():
            throw access;
          case PracticeOnlineAccessGranted():
            final transcriber = PracticeOnlineTranscriber(client: client);
            final recording = await transcriber.prepare(filePath);
            final upload = switch (recording) {
              PracticeRecordingUpload() => recording,
              // 复述首期只支持单块：超出即明确失败，不只上传开头。
              PracticeRecordingNeedsChunking(:final duration) => throw
                PracticeRecordingRejected(
                  duration == null
                      ? PracticeRecordingRejection.tooLarge
                      : PracticeRecordingRejection.tooLong,
                ),
            };
            final result = await transcriber.transcribe(
              config: access.config,
              apiKey: access.apiKey,
              modelId: access.modelId,
              recording: upload,
              cancelToken: cancelToken,
            );
            return RetellOnlineTranscript(
              text: result.text,
              identity: onlineRecognitionIdentity(access.config, access.modelId),
              modelId: access.modelId,
              serviceHost: Uri.tryParse(access.config.baseUrl)?.host ?? '',
              reportedCost: result.reportedCost,
            );
        }
      };
    });

class RetellReviewEvaluationController extends Notifier<RetellReviewEvaluationState> {
  CancelToken? _token;
  var _generation = 0;
  var _disposed = false;
  @override
  RetellReviewEvaluationState build() {
    ref.onDispose(() { _disposed = true; _token?.cancel('disposed'); });
    ref.listen(providerConfigurationProvider, (previous, _) {
      if (previous == null || previous.isLoading) return;
      _generation++; _token?.cancel('provider changed');
      state = RetellReviewEvaluationState(attemptKey: state.attemptKey);
    });
    return const RetellReviewEvaluationState();
  }

  void syncAttempt(String? attemptKey) {
    if (state.attemptKey == attemptKey) return;
    _generation++; _token?.cancel('attempt changed');
    state = RetellReviewEvaluationState(attemptKey: attemptKey);
  }

  Future<void> evaluate({required String attemptKey, required String recordingPath,
    required String originalText, required String targetLanguage,
    String? localTranscript, String? localTranscriptIdentity}) async {
    if (state.attemptKey != attemptKey) syncAttempt(attemptKey);
    if (state.hasCachedResult || state.phase == RetellReviewEvaluationPhase.loading ||
      state.phase == RetellReviewEvaluationPhase.streaming) {
      return;
    }
    final generation = ++_generation;
    _token?.cancel('restart');
    final token = CancelToken(); _token = token;
    state = RetellReviewEvaluationState(attemptKey: attemptKey,
      phase: RetellReviewEvaluationPhase.loading);
    try {
      final selection = ref.read(recognitionSettingsProvider).retell;
      final supplied = localTranscript?.trim();
      // 线下的身份就是选择本身；在线还要绑定实际服务与模型，否则换了在线模型
      // 也会被当成同一次结果。
      final onlineConfig = selection.usesOnlineModel
        ? await _retellOnlineConfig()
        : null;
      final expectedIdentity = onlineConfig == null
        ? selection.recognitionIdentity
        : onlineRecognitionIdentity(onlineConfig.config, onlineConfig.modelId);
      if (!_current(generation, attemptKey)) return;
      // 只复用同 attempt 且实际识别身份与复述选择一致的结果；身份缺失或不同
      // 来源（如字幕、跟读，或另一个在线模型）一律重新按复述自己的选择识别。
      final reusable = supplied != null && supplied.isNotEmpty &&
        localTranscriptIdentity == expectedIdentity;
      String? transcript;
      RetellOnlineSpeech? onlineSpeech;
      if (reusable) {
        transcript = supplied;
        if (onlineConfig != null) {
          // 复用的是早前的在线结果：本次没有新请求，费用如实标为未知。
          onlineSpeech = _speechOf(onlineConfig);
        }
      } else {
        final recognized = await _recognize(recordingPath, selection, token);
        if (!_current(generation, attemptKey)) return;
        // 识别期间复述的在线配置可能已被改：身份变了，这份文本不再代表当前选择。
        if (onlineConfig != null && !await _sameOnlineConfig(onlineConfig)) {
          if (!_current(generation, attemptKey)) return;
          AppLogger.log('RetellReview', '在线配置已变化，丢弃本次转写');
          state = RetellReviewEvaluationState(attemptKey: attemptKey);
          return;
        }
        transcript = recognized.text;
        onlineSpeech = recognized.onlineSpeech;
      }
      if (transcript == null || transcript.trim().isEmpty) {
        // 在线语音没给可用文本时按语音错误呈现；本机/系统沿用既有本机文案。
        if (onlineSpeech != null) {
          _fail(
            generation,
            attemptKey,
            null,
            speechError: const SpeechTranscriptionException(
              SpeechTranscriptionErrorKind.emptyResult,
            ),
          );
          return;
        }
        _fail(generation, attemptKey, 'transcription_failed');
        return;
      }
      await _evaluateText(generation, attemptKey, transcript, originalText,
        targetLanguage, token, onlineSpeech);
    } on Object catch (error) {
      if (token.isCancelled || !_current(generation, attemptKey)) return;
      // 到这里只有转写阶段的失败：不调用文字服务，语音错误单独呈现。
      AppLogger.log('RetellReview', '转写失败，未请求评估: ${error.runtimeType}');
      _fail(generation, attemptKey, null, speechError: error);
    } finally {
      if (identical(_token, token)) _token = null;
    }
  }

  /// 按复述自己的选择取得本次转写。
  ///
  /// 本机用复述自己的档位；在线用复述自己的在线模型并上传一次；系统识别只能随
  /// 录音会话产生实时结果，无法对录音文件二次转写，返回空文本由上层报告失败，
  /// 不自动改用其它方式。
  Future<_RecognizedTranscript> _recognize(String recordingPath,
    RecognitionSelection selection, CancelToken token) async {
    if (selection.usesOnlineModel) {
      final online = await ref.read(retellOnlineTranscriptProvider)(
        recordingPath, cancelToken: token);
      return _RecognizedTranscript(
        text: online.text,
        onlineSpeech: RetellOnlineSpeech(
          modelId: online.modelId,
          serviceHost: online.serviceHost,
          reportedCost: online.reportedCost,
        ),
      );
    }
    if (!selection.usesLocalModel) return const _RecognizedTranscript();
    return _RecognizedTranscript(
      text: await ref.read(retellTranscriptProvider)(recordingPath),
    );
  }

  /// 当前复述在线配置：服务与非空的在线模型；缺失时返回 null（无从证明来源）。
  Future<({SpeechConfig config, String modelId})?> _retellOnlineConfig() async {
    final config = await ref.read(speechConfigStoreProvider).read();
    if (config == null) return null;
    final modelId = config.onlineModelFor(RecognitionPurpose.retell);
    if (modelId.isEmpty) return null;
    return (config: config, modelId: modelId);
  }

  /// 当前复述在线配置是否仍是同一身份；配置变化后旧文本不能用。
  Future<bool> _sameOnlineConfig(
    ({SpeechConfig config, String modelId}) expected,
  ) async {
    final current = await _retellOnlineConfig();
    if (current == null) return false;
    return onlineRecognitionIdentity(current.config, current.modelId) ==
        onlineRecognitionIdentity(expected.config, expected.modelId);
  }

  /// 复用在线文本时的语音信息：本次没有新请求，费用为未知。
  RetellOnlineSpeech _speechOf(({SpeechConfig config, String modelId}) online) =>
    RetellOnlineSpeech(
      modelId: online.modelId,
      serviceHost: Uri.tryParse(online.config.baseUrl)?.host ?? '',
    );

  Future<void> _evaluateText(int generation, String attempt, String transcript,
    String original, String language, CancelToken token,
    RetellOnlineSpeech? onlineSpeech) async {
    var complete = false;
    await for (final frame in ref.read(sentenceAiApiClientProvider)
      .evaluateTranscriptStream(transcript: transcript, originalText: original,
        targetLanguage: language, cancelToken: token)) {
      if (!_current(generation, attempt)) return;
      complete = frame.isFinal;
      state = RetellReviewEvaluationState(attemptKey: attempt,
        phase: complete ? RetellReviewEvaluationPhase.completed : RetellReviewEvaluationPhase.streaming,
        evaluation: frame.evaluation, onlineSpeech: onlineSpeech);
    }
    if (!complete && _current(generation, attempt)) {
      _fail(generation, attempt, 'request_failed', onlineSpeech: onlineSpeech);
    }
  }

  bool _current(int generation, String attempt) => !_disposed &&
    generation == _generation && state.attemptKey == attempt;

  /// 失败回到可重试状态；[code] 是文字 AI 分类，[speechError] 是语音阶段原因。
  void _fail(int generation, String attempt, String? code, {
    Object? speechError, RetellOnlineSpeech? onlineSpeech}) {
    if (_current(generation, attempt)) {
      state = RetellReviewEvaluationState(attemptKey: attempt,
        phase: RetellReviewEvaluationPhase.failed, errorCode: code,
        speechError: speechError, onlineSpeech: onlineSpeech);
    }
  }

  void loadSample({required String attemptKey}) {
    assert(retellReviewSampleEnabled);
    _generation++; _token?.cancel('sample');
    state = RetellReviewEvaluationState(attemptKey: attemptKey,
      phase: RetellReviewEvaluationPhase.completed, evaluation: retellReviewSampleEvaluation());
  }
}

/// 本次识别得到的结果与它的来源。
///
/// 本机结果没有在线语音信息（null 表示未走在线），系统方式既没有文本也没有
/// 在线信息，由上层按识别失败处理。
class _RecognizedTranscript {
  const _RecognizedTranscript({this.text, this.onlineSpeech});

  final String? text;
  final RetellOnlineSpeech? onlineSpeech;
}
