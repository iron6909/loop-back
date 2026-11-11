import 'package:loop_back/widgets/practice/sense_group_action_bar.dart';
import 'package:loop_back/widgets/selection/selection_toolbar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('意群快捷条按顺序显示文字操作按钮并可点击', (tester) async {
    final calls = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SenseGroupActionBar(
              anchors: const TextSelectionToolbarAnchors(
                primaryAnchor: Offset(400, 300),
                secondaryAnchor: Offset(400, 330),
              ),
              actions: [
                SelectionToolbarAction(
                  label: 'Copy',
                  onPressed: () => calls.add('copy'),
                ),
                SelectionToolbarAction(
                  label: 'Save',
                  onPressed: () => calls.add('save'),
                ),
                SelectionToolbarAction(
                  label: 'Analysis',
                  onPressed: () => calls.add('analysis'),
                ),
                SelectionToolbarAction(
                  label: 'Ask AI',
                  onPressed: () => calls.add('chat'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Analysis'), findsOneWidget);
    expect(find.text('Ask AI'), findsOneWidget);
    expect(
      tester.getCenter(find.text('Copy')).dx,
      lessThan(tester.getCenter(find.text('Save')).dx),
    );
    expect(
      tester.getCenter(find.text('Save')).dx,
      lessThan(tester.getCenter(find.text('Analysis')).dx),
    );
    expect(
      tester.getCenter(find.text('Analysis')).dx,
      lessThan(tester.getCenter(find.text('Ask AI')).dx),
    );

    for (final label in ['Copy', 'Save', 'Analysis', 'Ask AI']) {
      await tester.tap(find.text(label));
      await tester.pump();
    }

    expect(calls, ['copy', 'save', 'analysis', 'chat']);
  });

  testWidgets('夜间模式下文字快捷条可见', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: SenseGroupActionBar(
              anchors: const TextSelectionToolbarAnchors(
                primaryAnchor: Offset(400, 300),
                secondaryAnchor: Offset(400, 330),
              ),
              actions: [
                SelectionToolbarAction(label: '复制', onPressed: () {}),
                SelectionToolbarAction(label: '收藏', onPressed: () {}),
                SelectionToolbarAction(label: '解析', onPressed: () {}),
                SelectionToolbarAction(label: '问 AI', onPressed: () {}),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('复制'), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('解析'), findsOneWidget);
    expect(find.text('问 AI'), findsOneWidget);
  });

  testWidgets('意群快捷条按钮宽度各自独立计算，悬浮反馈和点击光标正常', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SenseGroupActionBar(
            anchors: const TextSelectionToolbarAnchors(
              primaryAnchor: Offset(400, 300),
              secondaryAnchor: Offset(400, 330),
            ),
            actions: [
              SelectionToolbarAction(label: 'Copy', onPressed: () {}),
              SelectionToolbarAction(label: 'Remove', onPressed: () {}),
              SelectionToolbarAction(label: 'Ask AI', onPressed: () {}),
            ],
          ),
        ),
      ),
    );

    final copy = find.byKey(const Key('selection_toolbar_button_Copy'));
    final remove = find.byKey(const Key('selection_toolbar_button_Remove'));
    // 按钮宽度按各自文案独立计算，不再统一取最长文案的等宽——
    // 否则任一按钮文案变化（如收藏⇄取消收藏）都会牵动其余按钮跟着变宽。
    expect(
      tester.getSize(remove).width,
      greaterThan(tester.getSize(copy).width),
    );
    expect(
      tester
          .widget<MouseRegion>(
            find.descendant(of: copy, matching: find.byType(MouseRegion)).first,
          )
          .cursor,
      SystemMouseCursors.click,
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(copy));
    await tester.pump();
    final hovered = tester.widget<Container>(
      find.descendant(of: copy, matching: find.byType(Container)).first,
    );
    expect(hovered.color, isNot(Colors.transparent));
    final copyText = tester.widget<Text>(find.text('Copy'));
    expect(copyText.style?.fontWeight, FontWeight.normal);
    expect(copyText.style?.decoration, TextDecoration.none);
  });

  testWidgets('意群快捷条在顶部空间不足时翻到锚点下方并避让左右边界', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 240));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SenseGroupActionBar(
            anchors: const TextSelectionToolbarAnchors(
              primaryAnchor: Offset(8, 4),
              secondaryAnchor: Offset(8, 30),
            ),
            actions: [
              SelectionToolbarAction(label: 'Copy', onPressed: () {}),
              SelectionToolbarAction(label: 'Save', onPressed: () {}),
            ],
          ),
        ),
      ),
    );

    final surface = tester.getRect(
      find.byKey(const ValueKey('selection_toolbar_surface')),
    );
    expect(surface.top, greaterThanOrEqualTo(30));
    expect(surface.left, greaterThanOrEqualTo(0));
    expect(surface.right, lessThanOrEqualTo(320));
  });
}
