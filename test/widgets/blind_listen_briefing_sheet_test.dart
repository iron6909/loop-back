import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/l10n/app_localizations.dart';
import 'package:loop_back/models/study_stage.dart';
import 'package:loop_back/widgets/blind_listen_briefing_sheet.dart';
import 'package:loop_back/widgets/study/study_stage_visuals.dart';

import '../helpers/test_app.dart';

void main() {
  group('BlindListenBriefingSheet', () {
    testWidgets('顶部任务图标和颜色与学习任务列表一致', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showBlindListenBriefingSheet(
                context: context,
                isFirstStudy: true,
                onStartPractice: () {},
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final sheetContext = tester.element(
        find.byType(BlindListenBriefingSheet),
      );
      final expected = studyStageVisual(
        StudyStage.blindListen,
        AppLocalizations.of(sheetContext)!,
      );
      final heroIcon = tester.widget<Icon>(
        find.byWidgetPredicate((widget) => widget is Icon && widget.size == 56),
      );

      expect(heroIcon.icon, expected.icon);
      expect(heroIcon.color, expected.iconColor);
    });

    testWidgets('底部开始按钮避让系统安全区', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(bottom: 34);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);

      await tester.pumpWidget(
        createTestApp(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showBlindListenBriefingSheet(
                context: context,
                isFirstStudy: true,
                onStartPractice: () {},
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final actionButton = tester.getRect(find.byType(FilledButton));
      expect(actionButton.bottom, lessThanOrEqualTo(844 - 34));
    });

    testWidgets('首次学习模式 — 显示正确标题和提示', (tester) async {
      bool startPracticeCalled = false;

      await tester.pumpWidget(
        createTestApp(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showBlindListenBriefingSheet(
                  context: context,
                  isFirstStudy: true,
                  onStartPractice: () {
                    startPracticeCalled = true;
                  },
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // 验证标题和提示
      expect(find.text('Listen without subtitles'), findsOneWidget);
      expect(
        find.text('First Round - Listen without subtitles'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Challenge yourself: listen without subtitles and get the gist',
        ),
        findsOneWidget,
      );
      expect(find.text('Start Practicing'), findsOneWidget);

      // 点击开始练习
      await tester.tap(find.text('Start Practicing'));
      await tester.pumpAndSettle();

      expect(startPracticeCalled, true);
    });

    testWidgets('复习模式 — 显示复习轮次', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showBlindListenBriefingSheet(
                  context: context,
                  isFirstStudy: false,
                  reviewRound: 3,
                  onStartPractice: () {},
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Review 3 - Listen without subtitles'), findsOneWidget);
    });

    testWidgets('显示音频时长', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showBlindListenBriefingSheet(
                  context: context,
                  isFirstStudy: true,
                  audioDuration: const Duration(minutes: 3, seconds: 45),
                  onStartPractice: () {},
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('3:45'), findsOneWidget);
    });

    testWidgets('无音频时长时不显示时长行', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showBlindListenBriefingSheet(
                  context: context,
                  isFirstStudy: true,
                  onStartPractice: () {},
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // 无音频时长时不显示耳机图标
      expect(find.byIcon(Icons.schedule), findsNothing);
    });
  });
}
