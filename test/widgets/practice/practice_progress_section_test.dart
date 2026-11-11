/// 练习页进度条与句子信息行组件测试。
///
/// 验证只读进度条与可拖动滑块两种形态的切换，以及拖动跳转回调的取值。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/theme/app_theme.dart';
import 'package:loop_back/widgets/practice/practice_progress_section.dart';

/// 创建简易测试 App（进度与信息组件均不依赖 Riverpod）。
Widget _buildTestWidget({
  required int current,
  required int total,
  void Function(int targetIndex)? onSeek,
  Duration? elapsed,
  Duration? remaining,
  String? durationText,
  Widget? trailing,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          PracticeProgressBar(
            key: const ValueKey('practice-progress-section'),
            current: current,
            total: total,
            onSeek: onSeek,
            elapsed: elapsed,
            remaining: remaining,
          ),
          PracticeSentenceInfoRow(
            key: const ValueKey('practice-sentence-info-row'),
            progressText: '第 $current/$total 句',
            durationText: durationText,
            trailing: trailing,
          ),
        ],
      ),
    ),
  );
}

void main() {
  group('练习进度与信息组件', () {
    testWidgets('onSeek 为 null 时渲染只读进度条，无 Slider', (tester) async {
      await tester.pumpWidget(_buildTestWidget(current: 3, total: 10));

      expect(
        find.byKey(const ValueKey('practice-static-progress-bar')),
        findsOneWidget,
      );
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('total <= 1 时即使有 onSeek 也退化为只读进度条', (tester) async {
      await tester.pumpWidget(
        _buildTestWidget(current: 1, total: 1, onSeek: (_) {}),
      );

      expect(
        find.byKey(const ValueKey('practice-static-progress-bar')),
        findsOneWidget,
      );
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('onSeek 非 null 且 total > 1 时渲染可拖动滑块', (tester) async {
      await tester.pumpWidget(
        _buildTestWidget(current: 3, total: 10, onSeek: (_) {}),
      );

      expect(find.byType(Slider), findsOneWidget);
      expect(
        find.byKey(const ValueKey('practice-static-progress-bar')),
        findsNothing,
      );
    });

    testWidgets('可拖动进度条使用等高的纤细轨道', (tester) async {
      await tester.pumpWidget(
        _buildTestWidget(current: 3, total: 10, onSeek: (_) {}),
      );

      final slider = tester.widget<Slider>(find.byType(Slider));
      final sliderTheme = SliderTheme.of(tester.element(find.byType(Slider)));
      expect(slider.value, 3);
      expect(sliderTheme.trackHeight, 2);
      expect(
        sliderTheme.inactiveTrackColor,
        Theme.of(
          tester.element(find.byType(Slider)),
        ).colorScheme.surfaceContainerHighest,
      );
      expect(
        sliderTheme.trackShape.runtimeType.toString(),
        '_EqualHeightRoundedRectSliderTrackShape',
      );
    });

    testWidgets('整篇音频时长与进度条保持单行显示', (tester) async {
      await tester.pumpWidget(
        _buildTestWidget(
          current: 3,
          total: 10,
          onSeek: (_) {},
          elapsed: const Duration(seconds: 75),
          remaining: const Duration(seconds: 45),
        ),
      );

      expect(find.text('1:15'), findsOneWidget);
      expect(find.text('-0:45'), findsOneWidget);
      expect(
        tester.getCenter(find.text('1:15')).dy,
        closeTo(tester.getCenter(find.byType(Slider)).dy, 1),
      );
    });

    testWidgets('时长与右侧操作和句数显示在同一行', (tester) async {
      await tester.pumpWidget(
        _buildTestWidget(
          current: 2,
          total: 10,
          durationText: '5.5 秒',
          trailing: const Icon(Icons.bookmark_border),
        ),
      );

      final progress = tester.getCenter(find.text('第 2/10 句')).dy;
      expect(
        tester.getTopLeft(find.text('5.5 秒')).dx,
        greaterThan(tester.getTopRight(find.text('第 2/10 句')).dx),
      );
      expect(tester.getCenter(find.text('5.5 秒')).dy, closeTo(progress, 1));
      expect(find.text('·'), findsOneWidget);
      expect(
        tester.getCenter(find.byIcon(Icons.bookmark_border)).dy,
        closeTo(progress, 3),
      );
      expect(
        tester.getTopRight(find.byIcon(Icons.bookmark_border)).dx,
        closeTo(
          tester
                  .getTopRight(
                    find.byKey(const ValueKey('practice-progress-section')),
                  )
                  .dx -
              AppSpacing.m,
          1,
        ),
      );
    });

    testWidgets('进度条与信息行使用一致的水平边距', (tester) async {
      await tester.pumpWidget(_buildTestWidget(current: 2, total: 10));

      expect(
        tester
            .getRect(find.byKey(const ValueKey('practice-static-progress-bar')))
            .left,
        closeTo(tester.getRect(find.text('第 2/10 句')).left, 1),
      );
    });

    testWidgets('进度条保留拆分前的顶部留白', (tester) async {
      await tester.pumpWidget(_buildTestWidget(current: 2, total: 10));

      expect(
        tester
            .getRect(find.byKey(const ValueKey('practice-static-progress-bar')))
            .top,
        closeTo(AppSpacing.s, 1),
      );
    });

    testWidgets('只读进度条使用细轨道', (tester) async {
      await tester.pumpWidget(_buildTestWidget(current: 2, total: 10));

      expect(
        tester
            .getRect(find.byKey(const ValueKey('practice-static-progress-bar')))
            .height,
        closeTo(3, 0.1),
      );
    });

    testWidgets('拖动到末端松手回调 0-based 目标索引', (tester) async {
      int? seeked;
      await tester.pumpWidget(
        _buildTestWidget(current: 1, total: 10, onSeek: (i) => seeked = i),
      );

      // 从滑块中心向右拖到尽头并松手，应跳到最后一句（0-based = total - 1）
      await tester.drag(find.byType(Slider), const Offset(1000, 0));
      await tester.pumpAndSettle();

      expect(seeked, 9);
    });

    testWidgets('拖动到起点松手回调索引 0', (tester) async {
      int? seeked;
      await tester.pumpWidget(
        _buildTestWidget(current: 10, total: 10, onSeek: (i) => seeked = i),
      );

      await tester.drag(find.byType(Slider), const Offset(-1000, 0));
      await tester.pumpAndSettle();

      expect(seeked, 0);
    });
  });
}
