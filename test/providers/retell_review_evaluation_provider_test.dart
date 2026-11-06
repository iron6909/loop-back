/// 复述入口：无登录、复用转写、识别失败短路及 attempt 竞态。
library;
import 'dart:async';
import 'package:echo_loop/models/retell_review_evaluation.dart';
import 'package:echo_loop/providers/retell_review_evaluation_provider.dart';
import 'package:echo_loop/services/sentence_ai_api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Api extends Mock implements SentenceAiApiClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Api api;
  late ProviderContainer container;
  var transcriptions = 0;
  String? transcript;
  setUp(() {
    api = _Api(); transcriptions = 0; transcript = 'My retelling';
    when(() => api.evaluateTranscriptStream(
      transcript: any(named: 'transcript'), originalText: any(named: 'originalText'),
      targetLanguage: any(named: 'targetLanguage'), cancelToken: any(named: 'cancelToken'),
    )).thenAnswer((_) => Stream.value(const RetellReviewStreamFrame(
      evaluation: RetellReviewEvaluation(summary: '反馈'), isFinal: true)));
    container = ProviderContainer(overrides: [
      sentenceAiApiClientProvider.overrideWithValue(api),
      retellTranscriptProvider.overrideWithValue((_) async {
        transcriptions++; return transcript;
      }),
    ]);
  });
  tearDown(() => container.dispose());
  Future<void> evaluate({String key = 'attempt', String? reused}) => container
    .read(retellReviewEvaluationProvider.notifier).evaluate(attemptKey: key,
      recordingPath: '/recording.wav', originalText: 'Original',
      targetLanguage: 'zh-CN', localTranscript: reused);

  test('无需登录，本机转写后评估，重复打开复用当前 attempt', () async {
    await evaluate(); await evaluate();
    expect(container.read(retellReviewEvaluationProvider).phase,
      RetellReviewEvaluationPhase.completed);
    expect(transcriptions, 1);
    verify(() => api.evaluateTranscriptStream(transcript: 'My retelling',
      originalText: 'Original', targetLanguage: 'zh-CN',
      cancelToken: any(named: 'cancelToken'))).called(1);
  });
  test('同 attempt 的有效转写直接复用', () async {
    await evaluate(reused: 'Already recognized');
    expect(transcriptions, 0);
    expect(container.read(retellReviewEvaluationProvider).phase,
      RetellReviewEvaluationPhase.completed);
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
  test('切换 attempt 后旧转写不能写回或发请求', () async {
    final gate = Completer<String?>();
    container.dispose();
    container = ProviderContainer(overrides: [
      sentenceAiApiClientProvider.overrideWithValue(api),
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
