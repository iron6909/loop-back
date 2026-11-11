import 'package:drift/native.dart';
import 'package:loop_back/database/app_database.dart';
import 'package:loop_back/database/providers.dart';
import 'package:loop_back/features/review_statistics/review_statistics_provider.dart';
import 'package:loop_back/services/app_logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('统计加载失败时记录异常上下文', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement('DROP TABLE memory_schedules');
    AppLogger.instance.clear();
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    await expectLater(
      container.read(reviewStatisticsNotifierProvider.future),
      throwsA(anything),
    );

    expect(
      AppLogger.instance.entries.any(
        (entry) =>
            entry.tag == 'ReviewStatistics' && entry.message.contains('加载失败'),
      ),
      isTrue,
    );
  });
}
