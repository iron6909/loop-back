// 睡眠定时器 provider 单元测试。
//
// 用 fake_async 把墙钟与 Timer 一并冻结推进（provider 内部用 clock.now()），
// 覆盖：剩余递减、到点暂停一次、重设替换旧计时、取消不触发、dispose 取消 ticker。
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/providers/listening_practice/listening_practice_provider.dart';
import 'package:loop_back/providers/listening_practice/sleep_timer_provider.dart';

/// 测试替身：记录 pause 调用次数，build 跳过真实 I/O。
class _TestListeningPractice extends ListeningPractice {
  int pauseCount = 0;

  @override
  ListeningPracticeState build() => const ListeningPracticeState();

  @override
  Future<void> pause() async {
    pauseCount++;
  }
}

void main() {
  late ProviderContainer container;
  late _TestListeningPractice listening;

  ProviderContainer makeContainer() {
    listening = _TestListeningPractice();
    final c = ProviderContainer(
      overrides: [listeningPracticeProvider.overrideWith(() => listening)],
    );
    // autoDispose：保持一个常驻监听，避免无 listener 时被回收（对齐真实页面里
    // AppBar 按钮的 ref.watch）。
    c.listen(sleepTimerProvider, (_, __) {});
    return c;
  }

  tearDown(() => container.dispose());

  test('start 后激活且剩余随墙钟递减', () {
    fakeAsync((async) {
      container = makeContainer();
      final notifier = container.read(sleepTimerProvider.notifier);

      notifier.start(const Duration(minutes: 5));
      expect(container.read(sleepTimerProvider).isActive, true);
      expect(container.read(sleepTimerProvider).presetMinutes, 5);
      expect(
        container.read(sleepTimerProvider).remaining,
        const Duration(minutes: 5),
      );

      async.elapse(const Duration(minutes: 1));
      expect(container.read(sleepTimerProvider).presetMinutes, 5);
      expect(
        container.read(sleepTimerProvider).remaining,
        const Duration(minutes: 4),
      );
    });
  });

  test('到点暂停一次并清空状态', () {
    fakeAsync((async) {
      container = makeContainer();
      final notifier = container.read(sleepTimerProvider.notifier);

      notifier.start(const Duration(minutes: 5));
      async.elapse(const Duration(minutes: 5, seconds: 1));

      expect(listening.pauseCount, 1);
      expect(container.read(sleepTimerProvider).isActive, false);

      // 到点后 ticker 已停止，继续推进不再重复暂停。
      async.elapse(const Duration(minutes: 5));
      expect(listening.pauseCount, 1);
    });
  });

  test('重设替换旧计时：旧计时不再触发暂停', () {
    fakeAsync((async) {
      container = makeContainer();
      final notifier = container.read(sleepTimerProvider.notifier);

      notifier.start(const Duration(minutes: 5));
      async.elapse(const Duration(minutes: 4));
      // 在旧计时到点前重设为新的 10 分钟。
      notifier.start(const Duration(minutes: 10));
      expect(container.read(sleepTimerProvider).presetMinutes, 10);
      expect(
        container.read(sleepTimerProvider).remaining,
        const Duration(minutes: 10),
      );

      // 越过旧计时原本的到点时刻（再 2 分钟），不应触发暂停。
      async.elapse(const Duration(minutes: 2));
      expect(listening.pauseCount, 0);

      // 新计时到点才暂停。
      async.elapse(const Duration(minutes: 8, seconds: 1));
      expect(listening.pauseCount, 1);
    });
  });

  test('cancel 后不再触发暂停且恢复未激活', () {
    fakeAsync((async) {
      container = makeContainer();
      final notifier = container.read(sleepTimerProvider.notifier);

      notifier.start(const Duration(minutes: 5));
      async.elapse(const Duration(minutes: 1));
      notifier.cancel();
      expect(container.read(sleepTimerProvider).isActive, false);

      async.elapse(const Duration(minutes: 10));
      expect(listening.pauseCount, 0);
    });
  });

  test('dispose 取消 ticker，不再触发暂停', () {
    fakeAsync((async) {
      container = makeContainer();
      final notifier = container.read(sleepTimerProvider.notifier);

      notifier.start(const Duration(minutes: 5));
      async.elapse(const Duration(minutes: 1));
      container.dispose();

      async.elapse(const Duration(minutes: 10));
      expect(listening.pauseCount, 0);
    });

    // tearDown 会再次 dispose，已 disposed 容器重复 dispose 安全。
    container = makeContainer();
  });
}
