import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/features/community_collections/widgets/community_badge.dart';
import 'package:loop_back/models/collection.dart';
import 'package:loop_back/theme/app_theme.dart';

import '../../helpers/test_app.dart';

void main() {
  testWidgets('来源角标使用三种不同颜色', (tester) async {
    final expectedColors = {
      CollectionSource.local: AppTheme.localCollectionBadgeColor,
      CollectionSource.community: AppTheme.successColor,
      CollectionSource.podcast: AppTheme.podcastCollectionBadgeColor,
    };

    for (final source in CollectionSource.values) {
      await tester.pumpWidget(
        createTestApp(CollectionSourceCornerBadge(source: source)),
      );
      await tester.pumpAndSettle();

      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(CollectionSourceCornerBadge),
          matching: find.byType(Container),
        ),
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, expectedColors[source]);
    }

    expect(AppTheme.communityBadgeColor, AppTheme.successColor);
  });

  testWidgets('社区合集下架时使用 Removed 状态文案', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        const CollectionSourceCornerBadge(
          source: CollectionSource.community,
          isDeprecated: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Removed'), findsOneWidget);
    expect(find.text('Shared'), findsNothing);
  });
}
