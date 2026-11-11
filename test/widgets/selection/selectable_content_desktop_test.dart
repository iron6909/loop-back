/// 自有选区内核的桌面交互测试：双击选词 / Shift+点击 / Shift+方向键 / Cmd+C。
///
/// 这些能力是 `SelectableText` 白送、自有实现必须补齐的部分（CLAUDE.md §7.28）。
/// 用 [AppSelectableText] 直接测内核，不牵扯查词业务；分词注入最简空白切分。
library;

import 'package:loop_back/widgets/selection/app_selectable_text.dart';
import 'package:loop_back/widgets/selection/selection_toolbar.dart';
import 'package:loop_back/widgets/selection/selection_toolbar_host.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 桌面平台（键盘选区与鼠标拖选只在桌面出现）。
  final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);
  final clipboardTexts = <String>[];

  setUp(() {
    clipboardTexts.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardTexts.add(
              (call.arguments as Map)['text'] as String? ?? '',
            );
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// 空白切分的词边界（内核只认注入的规则，不用平台 ICU 边界）。
  TextRange? wordRangeAt(String text, int offset) {
    if (offset < 0 || offset > text.length) return null;
    var start = offset.clamp(0, text.length - 1);
    if (text[start] == ' ') return null;
    while (start > 0 && text[start - 1] != ' ') {
      start -= 1;
    }
    var end = offset.clamp(0, text.length);
    while (end < text.length && text[end] != ' ') {
      end += 1;
    }
    return end > start ? TextRange(start: start, end: end) : null;
  }

  Future<void> pumpText(
    WidgetTester tester,
    String text, {
    double width = 600,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionToolbarHost(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: AppSelectableText(
                  text: text,
                  style: const TextStyle(fontSize: 20, height: 1.5),
                  wordRange: (offset) => wordRangeAt(text, offset),
                  spanBuilder: (_) => [TextSpan(text: text)],
                  actionsBuilder: (selected) => [
                    SelectionToolbarAction(label: 'Copy', onPressed: () {}),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  AppSelectableTextState selectionState(WidgetTester tester) =>
      tester.state<AppSelectableTextState>(find.byType(AppSelectableText));

  RenderParagraph paragraph(WidgetTester tester) =>
      selectionState(tester).contentParagraph!;

  /// 字符区间中心的全局坐标。
  Offset centerOfRange(WidgetTester tester, int start, int end) {
    final boxes = paragraph(
      tester,
    ).getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end));
    return paragraph(tester).localToGlobal(boxes.first.toRect().center);
  }

  Offset wordCenter(WidgetTester tester, String text, String word) {
    final start = text.indexOf(word);
    return centerOfRange(tester, start, start + word.length);
  }

  /// 鼠标点击（只有鼠标交互才请求键盘焦点）。
  Future<void> mouseTapAt(WidgetTester tester, Offset position) async {
    await tester.tapAt(position, kind: PointerDeviceKind.mouse);
    await tester.pump();
  }

  Future<void> pressWithShift(
    WidgetTester tester,
    LogicalKeyboardKey key,
  ) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
  }

  const text = 'alpha beta gamma delta';

  testWidgets('鼠标单击立即选词，不等双击超时', (tester) async {
    // 双击靠自行判定时间窗，而非 DoubleTapGestureRecognizer——后者会 hold 住手势
    // 竞技场，让单击延迟约 300ms 才生效（点词查词整体变迟钝）。
    await pumpText(tester, text);
    await mouseTapAt(tester, wordCenter(tester, text, 'beta'));

    expect(selectionState(tester).selectedText, 'beta');
  }, variant: macOS);

  testWidgets('双击选词', (tester) async {
    await pumpText(tester, text);
    final target = wordCenter(tester, text, 'gamma');
    await mouseTapAt(tester, target);
    await tester.pump(kDoubleTapMinTime);
    await mouseTapAt(tester, target);

    expect(selectionState(tester).selectedText, 'gamma');
  }, variant: macOS);

  testWidgets('Shift+点击：保留固定端，扩选到点击处', (tester) async {
    await pumpText(tester, text);
    await mouseTapAt(tester, wordCenter(tester, text, 'alpha'));
    expect(selectionState(tester).selectedText, 'alpha');

    // 让上一次点击过期，避免被判成双击。
    await tester.pump(kDoubleTapTimeout * 2);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await mouseTapAt(tester, wordCenter(tester, text, 'gamma'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pumpAndSettle();

    final selected = selectionState(tester).selectedText;
    expect(selected, startsWith('alpha'));
    expect(selected, contains('beta'));
    expect(selected.length, greaterThan('alpha'.length));
  }, variant: macOS);

  testWidgets('Shift+方向键：左右按字符扩缩选区', (tester) async {
    await pumpText(tester, text);
    await mouseTapAt(tester, wordCenter(tester, text, 'beta'));
    expect(selectionState(tester).selectedText, 'beta');

    await pressWithShift(tester, LogicalKeyboardKey.arrowRight);
    expect(selectionState(tester).selectedText, 'beta ');

    await pressWithShift(tester, LogicalKeyboardKey.arrowRight);
    expect(selectionState(tester).selectedText, 'beta g');

    await pressWithShift(tester, LogicalKeyboardKey.arrowLeft);
    expect(selectionState(tester).selectedText, 'beta ');
  }, variant: macOS);

  testWidgets('Shift+↓：扩选到下一行', (tester) async {
    // 窄宽度强制折行，验证上下扩选走光标几何而非行结构假设。
    await pumpText(tester, text, width: 120);
    expect(paragraph(tester).size.height, greaterThan(40));

    await mouseTapAt(tester, wordCenter(tester, text, 'alpha'));
    expect(selectionState(tester).selectedText, 'alpha');

    await pressWithShift(tester, LogicalKeyboardKey.arrowDown);
    final selected = selectionState(tester).selectedText;
    expect(selected, startsWith('alpha'));
    // 折行后下一行是 'beta ...'，扩到下一行必然包含它（软换行不产生 \n 字符）。
    expect(selected, contains('beta'));
  }, variant: macOS);

  testWidgets('Cmd+C：复制选区且保留选区（与操作条的「复制」不同）', (tester) async {
    await pumpText(tester, text);
    await mouseTapAt(tester, wordCenter(tester, text, 'delta'));
    expect(selectionState(tester).selectedText, 'delta');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pump();

    expect(clipboardTexts, ['delta']);
    expect(selectionState(tester).selectedText, 'delta');
  }, variant: macOS);

  testWidgets('无选区时键盘不动作（本实现没有光标态）', (tester) async {
    await pumpText(tester, text);
    await mouseTapAt(tester, wordCenter(tester, text, 'beta'));
    selectionState(tester).endSession();
    await tester.pump();

    await pressWithShift(tester, LogicalKeyboardKey.arrowRight);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pump();

    expect(selectionState(tester).hasActiveSelection, isFalse);
    expect(clipboardTexts, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: macOS);

  testWidgets('鼠标按住拖动选择（桌面标准交互，字符级）', (tester) async {
    await pumpText(tester, text);
    // 起点取首字符左边界：光标吸附到最近的字符边界，从字形中心起拖会漏掉第一个字符。
    final firstChar = paragraph(tester)
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1),
        )
        .first
        .toRect();
    final start = paragraph(
      tester,
    ).localToGlobal(Offset(firstChar.left + 1, firstChar.center.dy));
    final end = centerOfRange(tester, 8, 9);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final selected = selectionState(tester).selectedText;
    expect(selected, startsWith('alpha'));
    expect(selected, contains('bet'));
  }, variant: macOS);
}
