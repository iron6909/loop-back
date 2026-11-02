import 'package:echo_loop/features/community_collections/data/community_sync_service.dart';
import 'package:echo_loop/models/audio_item.dart';
import 'package:echo_loop/models/collection.dart';
import 'package:echo_loop/providers/audio_library_provider.dart';
import 'package:echo_loop/providers/collection_provider.dart';
import 'package:echo_loop/screens/collection_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/mock_providers.dart';
import '../helpers/test_app.dart';

class _MockCommunitySyncService extends Mock implements CommunitySyncService {}

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

  CommunitySyncCompleted completed({
    int failedCollections = 0,
    int failedFiles = 0,
  }) => CommunitySyncCompleted(
    collectionsScanned: 1,
    collectionsDeprecated: 0,
    collectionsUndeprecated: 0,
    filesAdded: 0,
    filesRemoved: 0,
    failedCollections: failedCollections,
    failedFiles: failedFiles,
  );

  Future<_MockCommunitySyncService> pumpScreen(
    WidgetTester tester, {
    required List<AudioItem> audioItems,
    required CommunitySyncOutcome outcome,
  }) async {
    final syncService = _MockCommunitySyncService();
    when(
      () => syncService.syncCollection('community-local-1'),
    ).thenAnswer((_) async => outcome);

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
          communitySyncServiceProvider.overrideWithValue(syncService),
        ],
      ),
    );
    await tester.pumpAndSettle();
    return syncService;
  }

  testWidgets('历史社区合集显示只读说明，下拉不再同步且保留本地条目', (tester) async {
    final syncService = await pumpScreen(
      tester,
      audioItems: [audioItem()],
      outcome: completed(failedFiles: 1),
    );

    await tester.drag(find.byType(ListView).first, const Offset(0, 500));
    await tester.pumpAndSettle();

    verifyNever(() => syncService.syncCollection('community-local-1'));
    expect(find.byKey(const Key('community-read-only-notice')), findsOneWidget);
    expect(find.text('Short lesson'), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsNothing);
  });

  testWidgets('空历史社区合集保留只读说明且不发同步', (tester) async {
    final syncService = await pumpScreen(
      tester,
      audioItems: const [],
      outcome: completed(),
    );

    await tester.drag(find.byType(ListView).first, const Offset(0, 500));
    await tester.pumpAndSettle();

    verifyNever(() => syncService.syncCollection('community-local-1'));
    expect(find.byKey(const Key('community-read-only-notice')), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsNothing);
  });

  testWidgets('历史远端不可用不会触发同步或删除学习材料', (tester) async {
    final syncService = await pumpScreen(
      tester,
      audioItems: [audioItem()],
      outcome: const CommunitySyncFailed('network unavailable'),
    );

    await tester.drag(find.byType(ListView).first, const Offset(0, 500));
    await tester.pumpAndSettle();

    verifyNever(() => syncService.syncCollection('community-local-1'));
    expect(find.text('Short lesson'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });
}
