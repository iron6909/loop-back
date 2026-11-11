import 'package:clock/clock.dart';
import 'package:drift/native.dart';
import 'package:loop_back/database/app_database.dart' hide MemorySchedule;
import 'package:loop_back/features/memory_scheduler/adapters/fsrs/fsrs_memory_model_adapter.dart';
import 'package:loop_back/features/memory_scheduler/application/default_memory_scheduler.dart';
import 'package:loop_back/features/memory_scheduler/application/memory_model_registry.dart';
import 'package:loop_back/features/memory_scheduler/application/memory_scheduler.dart';
import 'package:loop_back/features/memory_scheduler/config/memory_profiles.dart';
import 'package:loop_back/features/memory_scheduler/data/drift_memory_schedule_repository.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_rating.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_schedule.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_scheduler_commands.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_scheduler_exceptions.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_subject_ref.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late DefaultMemoryScheduler scheduler;
  final createdAt = DateTime.utc(2026, 7, 26, 8);
  final subject = MemorySubjectRef(namespace: 'test', subjectId: 'subject-1');

  setUp(() {
    database = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) => raw.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    scheduler = DefaultMemoryScheduler(
      repository: DriftMemoryScheduleRepository(database),
      profileRegistry: kMemoryProfileRegistry,
      modelRegistry: StaticMemoryModelRegistry(<FsrsMemoryModelAdapter>[
        FsrsMemoryModelAdapter(),
      ]),
      idGenerator: _IncrementingIdGenerator(),
      clock: Clock.fixed(createdAt),
    );
  });

  tearDown(() => database.close());

  test('ensure 固定默认 Profile，预览不会写入快照', () async {
    final schedule = await scheduler.ensureSchedule(
      EnsureMemoryScheduleCommand(
        subject: subject,
        profile: null,
        occurredAt: createdAt,
      ),
    );
    final preview = await scheduler.previewRatings(
      PreviewMemoryRatingsQuery(
        subject: subject,
        reviewedAt: createdAt.add(const Duration(minutes: 1)),
        expectedRevision: schedule.revision,
      ),
    );

    expect(schedule.profile, kFsrsDefaultProfileRef);
    expect(preview.scheduleId, schedule.id);
    expect(preview.good.rating, MemoryRating.good);
    expect((await scheduler.getSchedule(subject))?.revision, 0);
  });

  test('评分重试按 operationId 返回原结果，旧 revision 的新操作失败', () async {
    final initial = await _ensure(scheduler, subject, createdAt);
    final command = ReviewMemoryCommand(
      subject: subject,
      rating: MemoryRating.good,
      reviewedAt: createdAt.add(const Duration(minutes: 1)),
      responseTime: const Duration(seconds: 1),
      operationId: 'operation-1',
      expectedRevision: initial.revision,
    );

    final first = await scheduler.review(command);
    final replay = await scheduler.review(command);
    expect(first.wasIdempotentReplay, isFalse);
    expect(replay.wasIdempotentReplay, isTrue);
    await expectLater(
      scheduler.review(
        ReviewMemoryCommand(
          subject: subject,
          rating: MemoryRating.good,
          reviewedAt: command.reviewedAt,
          responseTime: null,
          operationId: 'operation-2',
          expectedRevision: initial.revision,
        ),
      ),
      throwsA(isA<MemoryScheduleConflictException>()),
    );
  });

  test('旧 operationId 在后续评分后重试时显式拒绝过期回放', () async {
    final initial = await _ensure(scheduler, subject, createdAt);
    final firstCommand = ReviewMemoryCommand(
      subject: subject,
      rating: MemoryRating.good,
      reviewedAt: createdAt.add(const Duration(minutes: 1)),
      responseTime: null,
      operationId: 'operation-1',
      expectedRevision: initial.revision,
    );
    final first = await scheduler.review(firstCommand);
    await scheduler.review(
      ReviewMemoryCommand(
        subject: subject,
        rating: MemoryRating.good,
        reviewedAt: first.schedule.dueAt,
        responseTime: null,
        operationId: 'operation-2',
        expectedRevision: first.schedule.revision,
      ),
    );

    await expectLater(
      scheduler.review(firstCommand),
      throwsA(isA<MemoryIdempotencyReplayStaleException>()),
    );
  });

  test('旧开发期 operationId 不妨碍使用新唯一 ID 的下一次评分', () async {
    final initial = await _ensure(scheduler, subject, createdAt);
    final first = await scheduler.review(
      ReviewMemoryCommand(
        subject: subject,
        rating: MemoryRating.good,
        reviewedAt: createdAt.add(const Duration(minutes: 1)),
        responseTime: null,
        operationId: 'scheduled-flashcard-1',
        expectedRevision: initial.revision,
      ),
    );

    final second = await scheduler.review(
      ReviewMemoryCommand(
        subject: subject,
        rating: MemoryRating.good,
        reviewedAt: first.schedule.dueAt,
        responseTime: null,
        operationId: '550e8400-e29b-41d4-a716-446655440000',
        expectedRevision: first.schedule.revision,
      ),
    );

    expect(second.event.operationId, '550e8400-e29b-41d4-a716-446655440000');
    expect(second.schedule.revision, first.schedule.revision + 1);
  });

  test('归档调度不能预览或评分', () async {
    final initial = await _ensure(scheduler, subject, createdAt);
    await scheduler.archive(
      ArchiveMemoryScheduleCommand(
        subject: subject,
        archivedAt: createdAt.add(const Duration(minutes: 1)),
        expectedRevision: initial.revision,
      ),
    );

    await expectLater(
      scheduler.previewRatings(
        PreviewMemoryRatingsQuery(
          subject: subject,
          reviewedAt: createdAt.add(const Duration(minutes: 2)),
          expectedRevision: 1,
        ),
      ),
      throwsA(isA<MemoryScheduleArchivedException>()),
    );
    await expectLater(
      scheduler.review(
        ReviewMemoryCommand(
          subject: subject,
          rating: MemoryRating.good,
          reviewedAt: createdAt.add(const Duration(minutes: 2)),
          responseTime: null,
          operationId: 'operation-1',
          expectedRevision: 1,
        ),
      ),
      throwsA(isA<MemoryScheduleArchivedException>()),
    );
  });

  test('归档、恢复和永久清除均受 revision 保护', () async {
    final initial = await _ensure(scheduler, subject, createdAt);
    final archived = await scheduler.archive(
      ArchiveMemoryScheduleCommand(
        subject: subject,
        archivedAt: createdAt.add(const Duration(minutes: 1)),
        expectedRevision: initial.revision,
      ),
    );
    expect(archived.archivedAt, isNotNull);
    final restored = await scheduler.restore(
      RestoreMemoryScheduleCommand(
        subject: subject,
        restoredAt: createdAt.add(const Duration(minutes: 2)),
        expectedRevision: archived.revision,
      ),
    );
    await scheduler.purge(
      PurgeMemoryScheduleCommand(
        subject: subject,
        expectedRevision: restored.revision,
      ),
    );
    expect(await scheduler.getSchedule(subject), isNull);
  });
}

Future<MemorySchedule> _ensure(
  DefaultMemoryScheduler scheduler,
  MemorySubjectRef subject,
  DateTime createdAt,
) => scheduler.ensureSchedule(
  EnsureMemoryScheduleCommand(
    subject: subject,
    profile: null,
    occurredAt: createdAt,
  ),
);

final class _IncrementingIdGenerator implements MemoryIdGenerator {
  var _value = 0;

  @override
  String newId() => 'id-${_value++}';
}
