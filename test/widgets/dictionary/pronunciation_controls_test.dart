import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/l10n/app_localizations.dart';
import 'package:loop_back/models/pronunciation/pronunciation_clip.dart';
import 'package:loop_back/providers/pronunciation/pronunciation_providers.dart';
import 'package:loop_back/widgets/dictionary/pronunciation_controls.dart';

class _FakePlayback extends TextPlaybackController {
  @override
  TextPlaybackState build() => const TextPlaybackState();
  @override
  Future<void> play(
    PronunciationClip clip, {
    required String fallbackText,
    String? fallbackKey,
  }) async {}
}

Widget _wrap(Widget child) => ProviderScope(
  overrides: [textPlaybackProvider.overrideWith(_FakePlayback.new)],
  child: MaterialApp(
    locale: const Locale('en'),
    supportedLocales: const [Locale('en'), Locale('zh')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(body: child),
  ),
);

void main() {
  testWidgets('multiple clips render localized reason badges', (tester) async {
    const clips = [
      PronunciationClip(
        word: 'read',
        locale: 'us',
        audioFilename: 'read_us_v_past.opus',
        absolutePath: '/audio/read_us_v_past.opus',
        reason: PronunciationReason.pastTense,
      ),
      PronunciationClip(
        word: 'read',
        locale: 'us',
        audioFilename: 'read_us_v_present.opus',
        absolutePath: '/audio/read_us_v_present.opus',
        reason: PronunciationReason.presentTense,
      ),
    ];
    await tester.pumpWidget(
      _wrap(const PronunciationBadgeGroup(clips: clips, fallbackText: 'read')),
    );
    expect(find.text('Past tense'), findsOneWidget);
    expect(find.text('Present tense'), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsNWidgets(2));
  });
}
