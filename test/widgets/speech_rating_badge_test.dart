import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/l10n/app_localizations.dart';
import 'package:loop_back/models/speech_practice_models.dart';
import 'package:loop_back/services/audio_playback_service.dart';
import 'package:loop_back/services/audio_preview_controller.dart';
import 'package:loop_back/theme/app_theme.dart';
import 'package:loop_back/widgets/common/speech_rating_badge.dart';

class _FakeAudioPlaybackService extends AudioPlaybackService {
  Completer<void>? _playCompleter;
  int disposeCalls = 0;

  @override
  Future<void> play(String filePath) {
    _playCompleter = Completer<void>();
    return _playCompleter!.future;
  }

  @override
  Future<void> stop() async {
    _playCompleter?.complete();
    _playCompleter = null;
  }

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
    _playCompleter?.complete();
    _playCompleter = null;
  }
}

void main() {
  Widget createTestWidget({
    required _FakeAudioPlaybackService service,
    required SpeechPracticeAttempt attempt,
    Locale locale = const Locale('en'),
  }) {
    return MaterialApp(
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: SpeechRatingBadge(
              l10n: AppLocalizations.of(context)!,
              attempt: attempt,
              previewControllerFactory: () =>
                  AudioPreviewController(service: service),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('badge 自己管理播放图标切换', (tester) async {
    final service = _FakeAudioPlaybackService();

    await tester.pumpWidget(
      createTestWidget(
        service: service,
        attempt: const SpeechPracticeAttempt(
          promptId: 'test:0',
          filePath: '/tmp/test.m4a',
          finalTranscript: 'test transcript',
          score: 0.9,
          status: SpeechPracticeAttemptStatus.passed,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.volume_up_outlined), findsOneWidget);
    expect(find.byIcon(Icons.stop_rounded), findsNothing);

    await tester.tap(find.byType(SpeechRatingBadge));
    await tester.pump();

    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    expect(find.byIcon(Icons.volume_up_outlined), findsNothing);

    await tester.tap(find.byType(SpeechRatingBadge));
    await tester.pump();

    expect(find.byIcon(Icons.volume_up_outlined), findsOneWidget);
    expect(find.byIcon(Icons.stop_rounded), findsNothing);
  });

  testWidgets('已完成评估但 transcript 为空时仍显示评级 badge', (tester) async {
    final service = _FakeAudioPlaybackService();

    await tester.pumpWidget(
      createTestWidget(
        service: service,
        attempt: const SpeechPracticeAttempt(
          promptId: 'test:1',
          filePath: '/tmp/test.m4a',
          finalTranscript: '',
          score: 0.96,
          status: SpeechPracticeAttemptStatus.passed,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(SpeechRatingBadge)),
    )!;
    final badgeText = tester.widget<Text>(
      find.descendant(
        of: find.byType(SpeechRatingBadge),
        matching: find.byType(Text),
      ),
    );

    expect(find.text(l10n.listenAndRepeatRecordingOnly), findsNothing);
    expect(badgeText.data, l10n.listenAndRepeatRatingPerfect);
    expect(find.byIcon(Icons.volume_up_outlined), findsOneWidget);
  });

  testWidgets('识别失败时回退到录音 badge', (tester) async {
    final service = _FakeAudioPlaybackService();

    await tester.pumpWidget(
      createTestWidget(
        service: service,
        attempt: const SpeechPracticeAttempt(
          promptId: 'test:2',
          filePath: '/tmp/test.m4a',
          finalTranscript: '',
          status: SpeechPracticeAttemptStatus.noEnglishDetected,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(SpeechRatingBadge)),
    )!;

    expect(find.text(l10n.listenAndRepeatRecordingOnly), findsOneWidget);
    expect(find.text(l10n.listenAndRepeatRecognitionNoEnglish), findsNothing);
    expect(find.byIcon(Icons.volume_up_outlined), findsOneWidget);
  });

  testWidgets('外部注入的播放服务不由 badge dispose', (tester) async {
    final service = _FakeAudioPlaybackService();

    await tester.pumpWidget(
      createTestWidget(
        service: service,
        attempt: const SpeechPracticeAttempt(
          promptId: 'test:3',
          filePath: '/tmp/test.m4a',
          finalTranscript: 'test transcript',
          score: 0.9,
          status: SpeechPracticeAttemptStatus.passed,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(service.disposeCalls, 0);
  });
}
