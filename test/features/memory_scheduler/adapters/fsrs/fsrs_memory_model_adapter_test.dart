/// FSRS adapter 的确定性与状态边界回归测试。
library;

import 'package:loop_back/features/memory_scheduler/adapters/fsrs/fsrs_memory_model_adapter.dart';
import 'package:loop_back/features/memory_scheduler/adapters/fsrs/fsrs_state_codec.dart';
import 'package:loop_back/features/memory_scheduler/config/memory_profiles.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_model_adapter.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_rating.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_schedule.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_scheduler_exceptions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final adapter = FsrsMemoryModelAdapter();
  final createdAt = DateTime.utc(2026, 7, 26, 12);

  test('初始状态固定 cardId、UTC due 且不依赖当前时间', () {
    final state = adapter.createInitialState(
      profile: kFsrsDefaultProfile,
      createdAt: createdAt,
    );

    expect(state.version, kFsrsStateVersion);
    expect(state.values['cardId'], 0);
    expect(state.values['state'], 1);
    expect(state.values['due'], createdAt.toIso8601String());
  });

  test('预览完整覆盖四种评分且不修改输入状态', () {
    final state = adapter.createInitialState(
      profile: kFsrsDefaultProfile,
      createdAt: createdAt,
    );
    final originalDue = state.values['due'];
    final preview = adapter.preview(
      profile: kFsrsDefaultProfile,
      current: state,
      reviewedAt: createdAt,
    );

    expect(preview.again.phase, MemorySchedulePhase.learning);
    expect(preview.hard.phase, MemorySchedulePhase.learning);
    expect(preview.good.phase, MemorySchedulePhase.learning);
    expect(preview.easy.phase, MemorySchedulePhase.review);
    expect(state.values['due'], originalDue);
  });

  test('默认 Profile 开启 fuzzing，并产生合法 transition', () {
    var state = adapter.createInitialState(
      profile: kFsrsDefaultProfile,
      createdAt: createdAt,
    );
    var reviewedAt = createdAt;
    for (final rating in <MemoryRating>[
      MemoryRating.good,
      MemoryRating.good,
      MemoryRating.good,
    ]) {
      final transition = adapter.review(
        profile: kFsrsDefaultProfile,
        current: state,
        rating: rating,
        reviewedAt: reviewedAt,
      );
      state = transition.state;
      reviewedAt = transition.dueAt;
    }

    expect(state.values['state'], 2);
    expect(kFsrsDefaultProfile.enableFuzzing, isTrue);
    final due = state.values['due'];
    if (due is! String) fail('FSRS state due 必须是 ISO-8601 字符串。');
    expect(DateTime.parse(due), reviewedAt);
  });

  test('状态 codec 往返保持语义，未知版本显式失败', () {
    final initial = adapter.createInitialState(
      profile: kFsrsDefaultProfile,
      createdAt: createdAt,
    );
    final codec = FsrsStateCodec();
    final restored = codec.decode(initial);

    expect(codec.encode(restored).values, initial.values);
    expect(
      () => codec.decode(MemoryModelState(version: 2, values: initial.values)),
      throwsA(isA<MemoryModelStateUnsupportedException>()),
    );
  });
}
