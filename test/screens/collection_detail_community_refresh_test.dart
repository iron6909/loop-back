import 'package:loop_back/models/audio_item.dart';
import 'package:loop_back/models/collection.dart';
import 'package:loop_back/providers/audio_library_provider.dart';
import 'package:loop_back/providers/collection_provider.dart';
import 'package:loop_back/screens/collection_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/mock_providers.dart';
import '../helpers/test_app.dart';

void main() {
  final collection = Collection(
    id: 'community-local-1',
    name: 'Community English',
    createdDate: DateTime(2026, 6, 12),
    source: CollectionSource.community,
    remoteId: 'community-remote-1',
  );

  AudioItem audioItem() => AudioItem(
    id: 'audio-1',
    name: 'Short lesson',
    audioPath: null,
    remoteAudioId: 'remote-audio-1',
    addedDate: DateTime(2026, 6, 12),
  );

  Future<void> pumpScreen(
    WidgetTester tester, {
    required List<AudioItem> audioItems,
  }) async {
    await tester.pumpWidget(
      createTestScreen(
        const CollectionDetailScreen(collectionId: 'community-local-1'),
        overrides: [
          audioLibraryProvider.overrideWith(
            () => TestAudioLibrary(AudioLibraryState(audioItems: audioItems)),
          ),
          collectionListProvider.overrideWith(
            () => TestCollectionList(
              CollectionState(
                rawCollections: [collection],
                audioIdsMap: {
                  'community-local-1': audioItems
                      .map((item) => item.id)
                      .toList(),
                },
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('历史社区合集显示只读说明，下拉不再同步且保留本地条目', (tester) async {
    await pumpScreen(tester, audioItems: [audioItem()]);

    await tester.drag(find.byType(ListView).first, const Offset(0, 500));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('community-read-only-notice')), findsOneWidget);
    expect(find.text('Short lesson'), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsNothing);
  });

  testWidgets('空历史社区合集保留只读说明且不发同步', (tester) async {
    await pumpScreen(tester, audioItems: const []);

    await tester.drag(find.byType(ListView).first, const Offset(0, 500));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('community-read-only-notice')), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsNothing);
  });

  testWidgets('历史远端不可用不会触发同步或删除学习材料', (tester) async {
    await pumpScreen(tester, audioItems: [audioItem()]);

    await tester.drag(find.byType(ListView).first, const Offset(0, 500));
    await tester.pumpAndSettle();

    expect(find.text('Short lesson'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });
}
