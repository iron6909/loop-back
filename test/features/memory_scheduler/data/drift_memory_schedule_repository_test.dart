import 'package:drift/native.dart';
import 'package:loop_back/database/app_database.dart' hide MemorySchedule;
import 'package:loop_back/features/memory_scheduler/application/memory_schedule_repository.dart';
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
  late DriftMemoryScheduleRepository repository;

  setUp(() {
    database = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) => raw.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    repository = DriftMemoryScheduleRepository(database);
  });

  tearDown(() => database.close());

  test('到期查询使用稳定 keyset，并排除归档项', () async {
    final due = DateTime.utc(2026, 7, 26, 8);
    await repository.createIfAbsent(
      _schedule(id: 'a', subjectId: 'a', dueAt: due),
    );
    await repository.createIfAbsent(
      _schedule(id: 'b', subjectId: 'b', dueAt: due),
    );
    await repository.createIfAbsent(
      _schedule(
        id: 'c',
        subjectId: 'c',
        dueAt: due,
        status: MemoryScheduleStatus.archived,
      ),
    );

    final first = await repository.getDue(
      DueMemorySchedulesQuery(
        namespaces: const {'test'},
        phases: null,
        dueBeforeOrAt: due,
        limit: 1,
        after: null,
      ),
    );
    expect(first.single.id, 'a');
    final second = await repository.getDue(
      DueMemorySchedulesQuery(
        namespaces: const {'test'},
        phases: null,
        dueBeforeOrAt: due,
        limit: 10,
        after: MemoryDueCursor(dueAt: due, id: 'a'),
      ),
    );
    expect(second.map((schedule) => schedule.id), <String>['b']);
  });

  test('到期数量仅统计命名空间内的 active 到期快照', () async {
    final now = DateTime.utc(2026, 7, 26, 8);
    await repository.createIfAbsent(
      _schedule(id: 'due', subjectId: 'due', dueAt: now),
    );
    await repository.createIfAbsent(
      _schedule(
        id: 'future',
        subjectId: 'future',
        dueAt: now.add(const Duration(minutes: 1)),
      ),
    );
    await repository.createIfAbsent(
      _schedule(
        id: 'archived',
        subjectId: 'archived',
        dueAt: now,
        status: MemoryScheduleStatus.archived,
      ),
    );

    final count = await repository.getDueCount(
      DueMemoryCountQuery(
        namespaces: const {'test'},
        phases: null,
        dueBeforeOrAt: now,
      ),
    );

    expect(count, 1);
  });

  test('评分写入快照和事件，并对同一 operationId 幂等', () async {
    final before = _schedule(id: 'schedule-1', subjectId: 'one');
    await repository.createIfAbsent(before);
    final after = _reviewed(before);
    final reviewedAt = DateTime.utc(2026, 7, 26, 9);
    final commit = MemoryReviewCommit(
      before: before,
      after: after,
      event: MemoryReviewEventDraft(
        id: 'event-1',
        operationId: 'operation-1',
        rating: MemoryRating.good,
        isLapse: false,
        reviewedAt: reviewedAt,
        responseTime: const Duration(seconds: 2),
        dueBefore: before.dueAt,
        createdAt: reviewedAt,
      ),
      expectedRevision: before.revision,
    );

    final first = await repository.commitReview(commit);
    final replay = await repository.commitReview(commit);
    expect(first.wasIdempotentReplay, isFalse);
    expect(replay.wasIdempotentReplay, isTrue);
    expect((await repository.getEvents(before.id)).single.sequence, 1);
    final stored = await repository.getBySubject(before.subject);
    expect(stored?.revision, 1);
  });

  test('评分 revision 过期时不写入事件', () async {
    final before = _schedule(id: 'schedule-1', subjectId: 'one');
    await repository.createIfAbsent(before);
    final after = _reviewed(before);
    final reviewedAt = DateTime.utc(2026, 7, 26, 9);
    final stale = MemoryReviewCommit(
      before: before,
      after: after,
      event: MemoryReviewEventDraft(
        id: 'event-1',
        operationId: 'operation-1',
        rating: MemoryRating.good,
        isLapse: false,
        reviewedAt: reviewedAt,
        responseTime: null,
        dueBefore: before.dueAt,
        createdAt: reviewedAt,
      ),
      expectedRevision: before.revision,
    );
    await repository.commitReview(stale);
    await expectLater(
      repository.commitReview(
        MemoryReviewCommit(
          before: before,
          after: after,
          event: MemoryReviewEventDraft(
            id: 'event-2',
            operationId: 'operation-2',
            rating: MemoryRating.good,
            isLapse: false,
            reviewedAt: reviewedAt,
            responseTime: null,
            dueBefore: before.dueAt,
            createdAt: reviewedAt,
          ),
          expectedRevision: before.revision,
        ),
      ),
      throwsA(isA<MemoryScheduleConflictException>()),
    );
    expect(await repository.getEvents(before.id), hasLength(1));
  });
}

MemorySchedule _schedule({
  required String id,
  required String subjectId,
  DateTime? dueAt,
  MemoryScheduleStatus status = MemoryScheduleStatus.active,
}) {
  final createdAt = DateTime.utc(2026, 7, 26, 7);
  return MemorySchedule(
    id: id,
    subject: MemorySubjectRef(namespace: 'test', subjectId: subjectId),
    profile: kFsrsDefaultProfileRef,
    modelId: 'fsrs',
    modelStateVersion: 1,
    phase: MemorySchedulePhase.newItem,
    status: status,
    createdAt: createdAt,
    updatedAt: createdAt,
    lastReviewedAt: null,
    dueAt: dueAt ?? createdAt,
    reviewCount: 0,
    lapseCount: 0,
    revision: 0,
    modelState: const <String, Object?>{},
    archivedAt: status == MemoryScheduleStatus.archived ? createdAt : null,
  );
}

MemorySchedule _reviewed(MemorySchedule before) {
  final reviewedAt = DateTime.utc(2026, 7, 26, 9);
  return MemorySchedule(
    id: before.id,
    subject: before.subject,
    profile: before.profile,
    modelId: before.modelId,
    modelStateVersion: before.modelStateVersion,
    phase: MemorySchedulePhase.learning,
    status: MemoryScheduleStatus.active,
    createdAt: before.createdAt,
    updatedAt: reviewedAt,
    lastReviewedAt: reviewedAt,
    dueAt: reviewedAt.add(const Duration(minutes: 10)),
    reviewCount: 1,
    lapseCount: 0,
    revision: before.revision + 1,
    modelState: const <String, Object?>{'state': 'after'},
    archivedAt: null,
  );
}
