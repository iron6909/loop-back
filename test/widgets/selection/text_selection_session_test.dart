/// 选区会话（L1）状态流转单元测试
///
/// 这一层是「选区不随焦点丢失」的根据：官方 `SelectableText` / `SelectionArea`
/// 都在前台失焦时清选区，会话状态收到这里后，只有显式动作才能结束会话。
library;

import 'dart:ui';

import 'package:loop_back/widgets/selection/text_selection_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const contentA = 'alpha beta gamma';
  const contentB = 'delta epsilon';
  const word = TextRange(start: 6, end: 10);
  const phrase = TextRange(start: 0, end: 10);

  group('初始态', () {
    test('idle：无选区、无内容身份', () {
      final session = TextSelectionSession();
      expect(session.phase, TextSelectionPhase.idle);
      expect(session.range, isNull);
      expect(session.contentIdentity, isNull);
      expect(session.hasSelection, isFalse);
      expect(session.isActive, isFalse);
      expect(session.isSelecting, isFalse);
    });
  });

  group('activate（点词一步到已确认）', () {
    test('有效区间 → active', () {
      final session = TextSelectionSession()..activate(word, contentA);
      expect(session.phase, TextSelectionPhase.active);
      expect(session.range, word);
      expect(session.contentIdentity, contentA);
      expect(session.isActive, isTrue);
    });

    test('折叠区间等价于结束会话', () {
      final session = TextSelectionSession()..activate(word, contentA);
      session.activate(const TextRange(start: 3, end: 3), contentA);
      expect(session.phase, TextSelectionPhase.idle);
      expect(session.range, isNull);
    });

    test('无效区间等价于结束会话', () {
      final session = TextSelectionSession()..activate(word, contentA);
      session.activate(TextRange.empty, contentA);
      expect(session.phase, TextSelectionPhase.idle);
    });
  });

  group('拖选（selecting → active）', () {
    test('begin → update → commit：返回最终区间并转 active', () {
      final session = TextSelectionSession()..beginSelecting(word, contentA);
      expect(session.phase, TextSelectionPhase.selecting);
      expect(session.isSelecting, isTrue);
      expect(session.isActive, isFalse, reason: '拖动中不算已确认，不显示操作条');

      session.updateSelecting(phrase);
      expect(session.range, phrase);

      expect(session.commitSelecting(), phrase);
      expect(session.phase, TextSelectionPhase.active);
      expect(session.isActive, isTrue);
    });

    test('非拖动阶段的 update 被忽略', () {
      final session = TextSelectionSession()..activate(word, contentA);
      session.updateSelecting(phrase);
      expect(session.range, word);
    });

    test('非拖动阶段的 commit 返回 null（这次松手不该触发查询）', () {
      final session = TextSelectionSession()..activate(word, contentA);
      expect(session.commitSelecting(), isNull);
      expect(session.phase, TextSelectionPhase.active, reason: '状态不受影响');
    });

    test('update 到折叠/无效区间不覆盖已有选区', () {
      final session = TextSelectionSession()..beginSelecting(word, contentA);
      session.updateSelecting(const TextRange(start: 4, end: 4));
      expect(session.range, word);
    });

    test('begin 折叠区间不进入拖动态', () {
      final session = TextSelectionSession()
        ..beginSelecting(const TextRange(start: 2, end: 2), contentA);
      expect(session.phase, TextSelectionPhase.idle);
    });

    test('取消拖动：有选区则回到 active，保留选区', () {
      final session = TextSelectionSession()
        ..beginSelecting(word, contentA)
        ..updateSelecting(phrase);
      session.cancelSelecting();
      expect(session.phase, TextSelectionPhase.active);
      expect(session.range, phrase);
    });

    test('非拖动阶段取消是空操作', () {
      final session = TextSelectionSession()..activate(word, contentA);
      session.cancelSelecting();
      expect(session.phase, TextSelectionPhase.active);
      expect(session.range, word);
    });
  });

  group('结束与内容身份校验', () {
    test('end 清空全部状态', () {
      final session = TextSelectionSession()..activate(word, contentA);
      session.end();
      expect(session.phase, TextSelectionPhase.idle);
      expect(session.range, isNull);
      expect(session.contentIdentity, isNull);
    });

    test('内容未变：matchesContent 为真，不结束会话', () {
      final session = TextSelectionSession()..activate(word, contentA);
      expect(session.matchesContent(contentA), isTrue);
      expect(session.endIfContentChanged(contentA), isFalse);
      expect(session.phase, TextSelectionPhase.active);
    });

    test('内容变了：结束会话，不按旧字符偏移盲目恢复', () {
      final session = TextSelectionSession()..activate(word, contentA);
      expect(session.endIfContentChanged(contentB), isTrue);
      expect(session.phase, TextSelectionPhase.idle);
      expect(session.range, isNull);
    });

    test('idle 时内容变化不产生副作用', () {
      final session = TextSelectionSession();
      expect(session.endIfContentChanged(contentB), isFalse);
      expect(session.phase, TextSelectionPhase.idle);
    });

    test('拖动中内容变了也结束会话', () {
      final session = TextSelectionSession()..beginSelecting(word, contentA);
      expect(session.endIfContentChanged(contentB), isTrue);
      expect(session.phase, TextSelectionPhase.idle);
    });
  });
}
