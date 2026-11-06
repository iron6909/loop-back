import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../providers/audio_library_provider.dart';
import '../../../providers/collection_provider.dart';
import '../data/community_collection_repository.dart';

part 'community_enrollment_provider.g.dart';

/// 历史社区合集的本地移除入口。
///
/// 远端加入、同步与下载已停用；保留此入口是为了让用户仍能彻底删除
/// 已存在的历史合集及其本地数据。
@Riverpod(keepAlive: true)
class CommunityEnrollment extends _$CommunityEnrollment {
  @override
  void build() {}

  /// 移除社区合集及其本地媒体和学习记录。
  Future<void> remove(String localCollectionId) async {
    await ref
        .read(communityCollectionRepositoryProvider)
        .remove(localCollectionId);
    await ref.read(audioLibraryProvider.notifier).loadLibrary();
    await ref.read(collectionListProvider.notifier).loadCollections();
  }
}
