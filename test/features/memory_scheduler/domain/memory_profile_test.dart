/// 记忆调度领域契约与 Registry 回归测试。
library;

import 'package:loop_back/features/memory_scheduler/application/memory_model_registry.dart';
import 'package:loop_back/features/memory_scheduler/config/memory_profiles.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_model_adapter.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_namespaces.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_profile.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_rating.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_schedule.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_scheduler_commands.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_scheduler_exceptions.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_subject_ref.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MemorySubjectRef', () {
    test('按字段相等，并规范化两端空白', () {
      final first = MemorySubjectRef(namespace: ' word ', subjectId: ' id ');
      final second = MemorySubjectRef(namespace: 'word', subjectId: 'id');

      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });

    test('拒绝空标识', () {
      expect(
        () => MemorySubjectRef(namespace: ' ', subjectId: 'id'),
        throwsArgumentError,
      );
    });
  });

  group('MemoryProfile', () {
    test('Profile 引用按字段相等，并拒绝非法版本', () {
      expect(
        kFsrsDefaultProfileRef,
        MemoryProfileRef(profileId: 'fsrs.default', profileVersion: 1),
      );
      expect(
        () => MemoryProfileRef(profileId: 'fsrs.default', profileVersion: 0),
        throwsArgumentError,
      );
    });

    test('参数深层冻结，发布后的 Profile 不会被外部集合修改', () {
      final weights = <double>[1.0];
      final profile = MemoryProfile(
        ref: MemoryProfileRef(profileId: 'test', profileVersion: 1),
        modelId: 'test-model',
        parameters: <String, Object?>{'weights': weights},
        enableFuzzing: false,
      );
      weights.add(2.0);

      expect(profile.parameters['weights'], <Object?>[1.0]);
    });
  });

  group('MemoryProfileRegistry', () {
    test('所有 namespace 默认返回冻结的 fsrs.default@1', () {
      expect(
        kMemoryProfileRegistry.defaultForNamespace(kSavedSentenceNamespace),
        kFsrsDefaultProfileRef,
      );
      expect(
        kMemoryProfileRegistry.get(kFsrsDefaultProfileRef).enableFuzzing,
        isTrue,
      );
    });

    test('未知 Profile 显式失败', () {
      expect(
        () => kMemoryProfileRegistry.get(
          MemoryProfileRef(profileId: 'unknown', profileVersion: 1),
        ),
        throwsA(isA<MemoryProfileNotFoundException>()),
      );
    });
  });

  group('MemoryModelRegistry', () {
    test('未知模型显式失败', () {
      final registry = StaticMemoryModelRegistry(<MemoryModelAdapter>[]);
      expect(
        () => registry.get('missing'),
        throwsA(isA<MemoryModelNotFoundException>()),
      );
    });
  });

  group('Memory commands', () {
    test('到期查询规范化 UTC 并校验边界', () {
      final query = DueMemorySchedulesQuery(
        namespaces: <String>{' $kSavedWordOrPhraseNamespace '},
        phases: null,
        dueBeforeOrAt: DateTime(2026, 7, 26, 8),
        limit: 500,
        after: null,
      );

      expect(query.namespaces, <String>{kSavedWordOrPhraseNamespace});
      expect(query.dueBeforeOrAt.isUtc, isTrue);
      expect(
        () => DueMemorySchedulesQuery(
          namespaces: <String>{},
          phases: null,
          dueBeforeOrAt: DateTime.utc(2026),
          limit: 1,
          after: null,
        ),
        throwsArgumentError,
      );
      expect(
        () => DueMemorySchedulesQuery(
          namespaces: <String>{kSavedWordOrPhraseNamespace},
          phases: <MemorySchedulePhase>{},
          dueBeforeOrAt: DateTime.utc(2026),
          limit: 1,
          after: null,
        ),
        throwsArgumentError,
      );
    });

    test('评分命令拒绝超过一天的作答耗时', () {
      expect(
        () => ReviewMemoryCommand(
          subject: MemorySubjectRef(
            namespace: kSavedWordOrPhraseNamespace,
            subjectId: '1',
          ),
          rating: MemoryRating.good,
          reviewedAt: DateTime.utc(2026),
          responseTime: const Duration(hours: 25),
          operationId: 'op',
          expectedRevision: 0,
        ),
        throwsArgumentError,
      );
    });
  });
}
