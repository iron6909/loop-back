/// 复述评估：同 attempt 转写优先，本机识别成功后才请求供应商。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../features/subscription/models/ai_quota_rejection.dart';
import '../models/retell_review_evaluation.dart';
import '../models/retell_review_sample.dart';
import '../services/app_logger.dart';
import '../services/asr/offline_asr_engine.dart';
import '../services/provider/provider_http_client.dart';
import '../services/retell_transcriber.dart';
import '../services/sentence_ai_api_client.dart';
import 'asr_engine_provider.dart';
import 'local_transcription_task_provider.dart';
import 'provider_configuration_provider.dart';
import 'recognition_settings_provider.dart';
import '../models/recognition_selection.dart';

enum RetellReviewEvaluationPhase { idle, loading, streaming, completed, failed }

class RetellReviewEvaluationState {
  const RetellReviewEvaluationState({this.attemptKey,
    this.phase = RetellReviewEvaluationPhase.idle, this.evaluation, this.errorCode,
    this.quotaReason = AiQuotaRejectionReason.exhausted});
  final String? attemptKey;
  final RetellReviewEvaluationPhase phase;
  final RetellReviewEvaluation? evaluation;
  final String? errorCode;
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
      // 只复用同 attempt 且实际识别身份与复述选择一致的结果；身份缺失或不同
      // 来源（如字幕模型）一律重新按复述自己的选择识别。
      final reusable = supplied != null && supplied.isNotEmpty &&
        localTranscriptIdentity == selection.recognitionIdentity;
      final transcript = reusable ? supplied : await _transcribe(recordingPath, selection);
      if (!_current(generation, attemptKey)) return;
      if (transcript == null || transcript.trim().isEmpty) {
        _fail(generation, attemptKey, 'transcription_failed'); return;
      }
      await _evaluateText(generation, attemptKey, transcript, originalText,
        targetLanguage, token);
    } catch (error) {
      if (token.isCancelled || !_current(generation, attemptKey)) return;
      final code = error is ProviderNotConfiguredException ? 'not_configured'
        : error is ProviderHttpException ? error.kind.name : 'transcription_failed';
      AppLogger.log('RetellReview', '评估失败: ${error.runtimeType}');
      _fail(generation, attemptKey, code);
    } finally {
      if (identical(_token, token)) _token = null;
    }
  }

  /// 按复述自己的选择取得转写。
  ///
  /// 系统识别只能随录音会话产生实时结果，无法对录音文件二次转写；此时返回
  /// null 由上层报告识别失败，不自动改用其它方式。
  Future<String?> _transcribe(String recordingPath, RecognitionSelection selection) {
    if (!selection.usesLocalModel) return Future<String?>.value();
    return ref.read(retellTranscriptProvider)(recordingPath);
  }

  Future<void> _evaluateText(int generation, String attempt, String transcript,    String original, String language, CancelToken token) async {
    var complete = false;
    await for (final frame in ref.read(sentenceAiApiClientProvider)
      .evaluateTranscriptStream(transcript: transcript, originalText: original,
        targetLanguage: language, cancelToken: token)) {
      if (!_current(generation, attempt)) return;
      complete = frame.isFinal;
      state = RetellReviewEvaluationState(attemptKey: attempt,
        phase: complete ? RetellReviewEvaluationPhase.completed : RetellReviewEvaluationPhase.streaming,
        evaluation: frame.evaluation);
    }
    if (!complete && _current(generation, attempt)) _fail(generation, attempt, 'request_failed');
  }

  bool _current(int generation, String attempt) => !_disposed &&
    generation == _generation && state.attemptKey == attempt;
  void _fail(int generation, String attempt, String code) {
    if (_current(generation, attempt)) {
      state = RetellReviewEvaluationState(
      attemptKey: attempt, phase: RetellReviewEvaluationPhase.failed, errorCode: code);
    }
  }

  void loadSample({required String attemptKey}) {
    assert(retellReviewSampleEnabled);
    _generation++; _token?.cancel('sample');
    state = RetellReviewEvaluationState(attemptKey: attemptKey,
      phase: RetellReviewEvaluationPhase.completed, evaluation: retellReviewSampleEvaluation());
  }
}
