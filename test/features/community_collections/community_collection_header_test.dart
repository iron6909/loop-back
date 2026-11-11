import 'package:loop_back/features/community_collections/widgets/community_collection_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  testWidgets('short description shows collection details without disclosure', (
    tester,
  ) async {
    await tester.pumpWidget(
      createTestApp(
        Scaffold(
          body: CommunityCollectionHeader(
            description: 'A short collection.',
            authorNickname: 'Echo Studio',
            updatedAt: DateTime(2026, 9, 24, 15, 7),
            fileCount: 4,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Echo Studio'), findsOneWidget);
    expect(find.text('2026-09-24 15:07'), findsOneWidget);
    expect(find.text('By Echo Studio'), findsNothing);
    expect(find.text('Date unknown'), findsNothing);
    expect(find.text('4 items'), findsOneWidget);
    expect(find.text('Show more'), findsNothing);
    final metadataRow = tester.getRect(
      find.byKey(const ValueKey('community-collection-metadata-row')),
    );
    final authorRect = tester.getRect(
      find.byKey(const ValueKey('community-collection-author-metadata')),
    );
    final updateRect = tester.getRect(
      find.byKey(const ValueKey('community-collection-updated-metadata')),
    );
    final countRect = tester.getRect(
      find.byKey(const ValueKey('community-collection-count-metadata')),
    );
    final metadataRect = tester.getRect(
      find.byKey(const ValueKey('community-collection-metadata-row')),
    );
    expect(authorRect.left, closeTo(metadataRow.left, 1));
    expect(countRect.right, closeTo(metadataRect.right, 1));
    final leftGap = updateRect.left - authorRect.right;
    final rightGap = countRect.left - updateRect.right;
    expect(leftGap, greaterThanOrEqualTo(8));
    expect(rightGap, greaterThanOrEqualTo(8));
    expect(leftGap, closeTo(rightGap, 1));
  });

  testWidgets('long description can expand and collapse', (tester) async {
    const description =
        'This is a long community collection description with enough detail '
        'to continue across several lines on a phone screen. It explains the '
        'topics and materials included in the collection, how learners can '
        'use them for regular listening practice, and what makes this set '
        'helpful for building English skills over time.';
    await tester.pumpWidget(
      createTestApp(
        const Scaffold(
          body: CommunityCollectionHeader(
            description: description,
            authorNickname: null,
            fileCount: 4,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final descriptionFinder = find.byKey(
      const ValueKey('community-collection-description'),
    );
    final collapsedText = tester.widget<Text>(descriptionFinder);
    expect(collapsedText.maxLines, 3);
    expect(collapsedText.textSpan!.toPlainText(), contains('More'));
    final textPainter = TextPainter(
      text: collapsedText.textSpan,
      textDirection: Directionality.of(tester.element(descriptionFinder)),
      textScaler: MediaQuery.textScalerOf(tester.element(descriptionFinder)),
      maxLines: collapsedText.maxLines,
    )..layout(maxWidth: tester.getSize(descriptionFinder).width);
    expect(textPainter.computeLineMetrics(), hasLength(3));
    textPainter.dispose();
    expect(find.text('Unknown author'), findsOneWidget);
    expect(find.text('Date unknown'), findsNothing);

    await _tapInlineAction(tester, descriptionFinder, 'More');
    await tester.pumpAndSettle();

    final expandedText = tester.widget<Text>(descriptionFinder);
    expect(expandedText.maxLines, isNull);
    expect(expandedText.textSpan!.toPlainText(), contains(description));
    expect(expandedText.textSpan!.toPlainText(), contains('Less'));

    await _tapInlineAction(tester, descriptionFinder, 'Less');
    await tester.pumpAndSettle();

    final recollapsedText = tester.widget<Text>(descriptionFinder);
    expect(recollapsedText.maxLines, 3);
    expect(recollapsedText.textSpan!.toPlainText(), contains('More'));
  });
}

Future<void> _tapInlineAction(
  WidgetTester tester,
  Finder textFinder,
  String label,
) async {
  final text = tester.widget<Text>(textFinder).textSpan!.toPlainText();
  final start = text.lastIndexOf(label);
  expect(start, isNonNegative);

  final paragraph = tester.renderObject<RenderParagraph>(textFinder);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: start + label.length),
  );
  expect(boxes, isNotEmpty);
  await tester.tapAt(paragraph.localToGlobal(boxes.first.toRect().center));
}
