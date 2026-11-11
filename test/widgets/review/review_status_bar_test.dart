import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/widgets/review/review_status_bar.dart';

void main() {
  testWidgets('renders elapsed time and reviewed count', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ReviewStatusBar(
          elapsed: () => const Duration(minutes: 1, seconds: 2),
          reviewedCount: 3,
          remainingCount: 2,
          elapsedLabel: '学习时长',
          reviewedLabel: '已复习',
          remainingLabel: '剩余',
        ),
      ),
    );

    expect(find.text('01:02'), findsOneWidget);
    expect(find.text('已复习 3'), findsOneWidget);
    expect(find.text('剩余 2'), findsOneWidget);
  });

  testWidgets('uses a wider gap between the two metrics', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ReviewStatusBar(
          elapsed: () => const Duration(minutes: 1),
          reviewedCount: 3,
          remainingCount: 2,
          elapsedLabel: '学习时长',
          reviewedLabel: '已复习',
          remainingLabel: '剩余',
        ),
      ),
    );

    final time = tester.getTopRight(find.text('01:00'));
    final reviewed = tester.getTopLeft(find.text('已复习 3'));
    expect(reviewed.dx - time.dx, greaterThanOrEqualTo(36));
  });

  testWidgets('uses compact vertical padding', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: ReviewStatusBar(
              elapsed: () => Duration.zero,
              reviewedCount: 0,
              remainingCount: 0,
              elapsedLabel: 'Study time',
              reviewedLabel: 'Reviewed',
              remainingLabel: 'Remaining',
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(ReviewStatusBar)).height, lessThan(24));
  });

  testWidgets('避让系统底部安全区', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(viewPadding: EdgeInsets.only(bottom: 24)),
        child: MaterialApp(
          home: ReviewStatusBar(
            elapsed: () => Duration.zero,
            reviewedCount: 0,
            remainingCount: 0,
            elapsedLabel: 'Study time',
            reviewedLabel: 'Reviewed',
            remainingLabel: 'Remaining',
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(ReviewStatusBar)).height,
      greaterThan(24),
    );
  });

  testWidgets('ticks locally without losing count', (tester) async {
    var elapsed = Duration.zero;
    await tester.pumpWidget(
      MaterialApp(
        home: ReviewStatusBar(
          elapsed: () => elapsed,
          reviewedCount: 2,
          remainingCount: 1,
          elapsedLabel: 'Study time',
          reviewedLabel: 'Reviewed',
          remainingLabel: 'Remaining',
        ),
      ),
    );
    elapsed = const Duration(seconds: 1);
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('00:01'), findsOneWidget);
    expect(find.text('Reviewed 2'), findsOneWidget);
  });

  testWidgets('shows hours only after reaching one hour', (tester) async {
    var elapsed = const Duration(minutes: 59, seconds: 59);
    await tester.pumpWidget(
      MaterialApp(
        home: ReviewStatusBar(
          elapsed: () => elapsed,
          reviewedCount: 1,
          remainingCount: 0,
          elapsedLabel: 'Study time',
          reviewedLabel: 'Reviewed',
          remainingLabel: 'Remaining',
        ),
      ),
    );
    expect(find.text('59:59'), findsOneWidget);
    elapsed = const Duration(hours: 1);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1:00:00'), findsOneWidget);
  });
}
