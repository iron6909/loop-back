/// 复述入口：无登录、按复述自己的识别身份复用转写、识别失败短路及 attempt 竞态。
library;
import 'dart:async';
import 'package:echo_loop/models/recognition_selection.dart';
import 'package:echo_loop/models/retell_review_evaluation.dart';
import 'package:echo_loop/providers/recognition_settings_provider.dart';
import 'package:echo_loop/providers/retell_review_evaluation_provider.dart';
import 'package:echo_loop/services/sentence_ai_api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Api extends Mock implements SentenceAiApiClient {}

/// 固定复述选择，避免测试依赖偏好读写。
class _FixedRecognitionSettings extends RecognitionSettingsNotifier {
  _FixedRecognitionSettings(this._fixed);

  final RecognitionSettings _fixed;

  @override
  RecognitionSettings build() => _fixed;
}

const _retellModelId = 'retell-model';

RecognitionSettings _retellLocal() => const RecognitionSettings(
  subtitle: RecognitionSelection.local('subtitle-model'),
  shadowing: RecognitionSelection.local('shadowing-model'),
  retell: RecognitionSelection.local(_retellModelId),
);

RecognitionSettings _retellSystem() => const RecognitionSettings(
  subtitle: RecognitionSelection.local('subtitle-model'),
  shadowing: RecognitionSelection.local('shadowing-model'),
  retell: RecognitionSelection.system(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Api api;
  late ProviderContainer container;
  var transcriptions = 0;
  String? transcript;

  ProviderContainer buildContainer({required RecognitionSettings settings}) =>
      ProviderContainer(overrides: [
        sentenceAiApiClientProvider.overrideWithValue(api),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(settings),
        ),
        retellTranscriptProvider.overrideWithValue((_) async {
          transcriptions++; return transcript;
        }),
      ]);

  setUp(() {
    api = _Api(); transcriptions = 0; transcript = 'My retelling';
    when(() => api.evaluateTranscriptStream(
      transcript: any(named: 'transcript'), originalText: any(named: 'originalText'),
      targetLanguage: any(named: 'targetLanguage'), cancelToken: any(named: 'cancelToken'),
    )).thenAnswer((_) => Stream.value(const RetellReviewStreamFrame(
      evaluation: RetellReviewEvaluation(summary: '反馈'), isFinal: true)));
    container = buildContainer(settings: _retellLocal());
  });
  tearDown(() => container.dispose());

  Future<void> evaluate({String key = 'attempt', String? reused,
    String? reusedIdentity}) => container
    .read(retellReviewEvaluationProvider.notifier).evaluate(attemptKey: key,
      recordingPath: '/recording.wav', originalText: 'Original',
      targetLanguage: 'zh-CN', localTranscript: reused,
      localTranscriptIdentity: reusedIdentity);

  test('无需登录，本机转写后评估，重复打开复用当前 attempt', () async {
    await evaluate(); await evaluate();
    expect(container.read(retellReviewEvaluationProvider).phase,
      RetellReviewEvaluationPhase.completed);
    expect(transcriptions, 1);
    verify(() => api.evaluateTranscriptStream(transcript: 'My retelling',
      originalText: 'Original', targetLanguage: 'zh-CN',
      cancelToken: any(named: 'cancelToken'))).called(1);
  });
  test('同 attempt 且实际识别身份匹配的转写直接复用', () async {
    await evaluate(reused: 'Already recognized',
      reusedIdentity: 'local:$_retellModelId');
    expect(transcriptions, 0);
    expect(container.read(retellReviewEvaluationProvider).phase,
      RetellReviewEvaluationPhase.completed);
  });
  test('识别身份不匹配时不复用，按复述自己的选择重新转写', () async {
    await evaluate(reused: 'Borrowed from subtitle',
      reusedIdentity: 'local:subtitle-model');
    expect(transcriptions, 1);
    verify(() => api.evaluateTranscriptStream(transcript: 'My retelling',
      originalText: 'Original', targetLanguage: 'zh-CN',
      cancelToken: any(named: 'cancelToken'))).called(1);
  });
  test('没有识别身份的旧转写不能当作同源结果复用', () async {
    await evaluate(reused: 'Unknown source');
    expect(transcriptions, 1);
  });
  test('转写失败不调用供应商', () async {
    transcript = null;
    await evaluate();
    expect(container.read(retellReviewEvaluationProvider).errorCode,
      'transcription_failed');
    verifyNever(() => api.evaluateTranscriptStream(
      transcript: any(named: 'transcript'), originalText: any(named: 'originalText'),
      targetLanguage: any(named: 'targetLanguage'), cancelToken: any(named: 'cancelToken')));
  });
  test('系统识别方式无法对录音文件转写时明确失败，不自动改用其它方式', () async {
    container.dispose();
    container = buildContainer(settings: _retellSystem());
    await evaluate(reused: 'Other source', reusedIdentity: 'local:subtitle-model');
    expect(transcriptions, 0, reason: '系统方式不能对录音文件做二次转写');
    expect(container.read(retellReviewEvaluationProvider).errorCode,
      'transcription_failed');
    verifyNever(() => api.evaluateTranscriptStream(
      transcript: any(named: 'transcript'), originalText: any(named: 'originalText'),
      targetLanguage: any(named: 'targetLanguage'), cancelToken: any(named: 'cancelToken')));
  });
  test('切换 attempt 后旧转写不能写回或发请求', () async {
    final gate = Completer<String?>();
    container.dispose();
    container = ProviderContainer(overrides: [
      sentenceAiApiClientProvider.overrideWithValue(api),
      recognitionSettingsProvider.overrideWith(
        () => _FixedRecognitionSettings(_retellLocal()),
      ),
      retellTranscriptProvider.overrideWithValue((_) => gate.future),
    ]);
    final pending = evaluate();
    container.read(retellReviewEvaluationProvider.notifier).syncAttempt('next');
    gate.complete('Old transcript'); await pending;
    expect(container.read(retellReviewEvaluationProvider).attemptKey, 'next');
    expect(container.read(retellReviewEvaluationProvider).evaluation, isNull);
    verifyNever(() => api.evaluateTranscriptStream(
      transcript: any(named: 'transcript'), originalText: any(named: 'originalText'),
      targetLanguage: any(named: 'targetLanguage'), cancelToken: any(named: 'cancelToken')));
  });
}
