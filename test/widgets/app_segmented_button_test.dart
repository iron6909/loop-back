import 'package:loop_back/theme/app_theme.dart';
import 'package:loop_back/widgets/common/app_segmented_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('统一选中态、未选中态和文字样式', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: AppSegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 1, label: Text('One')),
            ButtonSegment(value: 2, label: Text('Two')),
          ],
          selected: const {1},
          onSelectionChanged: (_) {},
        ),
      ),
    );

    final selector = tester.widget<SegmentedButton<int>>(
      find.byType(SegmentedButton<int>),
    );
    final style = selector.style!;
    final theme = Theme.of(
      tester.element(find.byType(AppSegmentedButton<int>)),
    );

    expect(selector.showSelectedIcon, isFalse);
    expect(style.minimumSize!.resolve({})!.height, 44);
    expect(
      style.backgroundColor!.resolve({WidgetState.selected}),
      theme.colorScheme.primaryContainer,
    );
    expect(style.backgroundColor!.resolve({}), theme.colorScheme.surface);
    expect(style.side!.resolve({})!.color, theme.colorScheme.outlineVariant);
    expect(style.textStyle!.resolve({})!.fontWeight, FontWeight.w700);
  });

  testWidgets('可单独收紧选择器高度', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AppSegmentedButton<int>(
              minimumHeight: 30,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: EdgeInsets.zero,
              segments: const [ButtonSegment(value: 1, label: Text('One'))],
              selected: const {1},
              onSelectionChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.byType(SegmentedButton<int>), findsNothing);
    expect(tester.getSize(find.byType(AppSegmentedButton<int>)).height, 30);
    expect(tester.getSize(find.text('One')).height, greaterThan(14));
  });

  testWidgets('窄屏时按可用宽度均分且不溢出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 140,
            child: AppSegmentedButton<int>(
              minimumHeight: 30,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: EdgeInsets.zero,
              segments: const [
                ButtonSegment(value: 1, label: Text('一')),
                ButtonSegment(value: 2, label: Text('二')),
                ButtonSegment(value: 3, label: Text('三')),
                ButtonSegment(value: 4, label: Text('四')),
              ],
              selected: const {1},
              onSelectionChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(AppSegmentedButton<int>)),
      const Size(140, 30),
    );
  });

  testWidgets('紧凑模式保留图标和文字，并阻止禁用项交互', (tester) async {
    var selectedValue = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: AppSegmentedButton<int>(
              minimumHeight: 30,
              segments: const [
                ButtonSegment(
                  value: 1,
                  icon: Icon(Icons.check),
                  label: Text('Enabled'),
                ),
                ButtonSegment(
                  value: 2,
                  icon: Icon(Icons.lock),
                  label: Text('Disabled'),
                  enabled: false,
                ),
              ],
              selected: const {1},
              onSelectionChanged: (value) => selectedValue = value.first,
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.text('Enabled'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);

    await tester.tap(find.text('Disabled'));
    expect(selectedValue, 1);
  });
}
