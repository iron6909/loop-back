import 'dart:async';

import 'package:loop_back/services/refresh_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RefreshCoordinator', () {
    late DateTime now;
    late RefreshCoordinator<String, String> coordinator;

    setUp(() {
      now = DateTime(2026, 6, 14, 12);
      coordinator = RefreshCoordinator<String, String>(now: () => now);
    });

    test('未过节流窗口且 force=false 时不执行 refresh', () async {
      var calls = 0;

      final result = await coordinator.run(
        key: 'catalog',
        force: false,
        lastRefreshedAt: now.subtract(const Duration(minutes: 3)),
        throttleWindow: const Duration(minutes: 10),
        refresh: () async {
          calls++;
          return 'fresh';
        },
      );

      expect(result, isA<RefreshThrottled<String>>());
      expect(calls, 0);
    });

    test('已过节流窗口时执行 refresh', () async {
      var calls = 0;

      final result = await coordinator.run(
        key: 'catalog',
        force: false,
        lastRefreshedAt: now.subtract(const Duration(minutes: 11)),
        throttleWindow: const Duration(minutes: 10),
        refresh: () async {
          calls++;
          return 'fresh';
        },
      );

      expect(result, isA<RefreshCompleted<String>>());
      expect((result as RefreshCompleted<String>).result, 'fresh');
      expect(calls, 1);
    });

    test('lastRefreshedAt 为 null 时执行 refresh', () async {
      var calls = 0;

      final result = await coordinator.run(
        key: 'catalog',
        force: false,
        lastRefreshedAt: null,
        throttleWindow: const Duration(minutes: 10),
        refresh: () async {
          calls++;
          return 'fresh';
        },
      );

      expect(result, isA<RefreshCompleted<String>>());
      expect(calls, 1);
    });

    test('force=true 时绕过节流', () async {
      var calls = 0;

      final result = await coordinator.run(
        key: 'catalog',
        force: true,
        lastRefreshedAt: now,
        throttleWindow: const Duration(minutes: 10),
        refresh: () async {
          calls++;
          return 'fresh';
        },
      );

      expect(result, isA<RefreshCompleted<String>>());
      expect(calls, 1);
    });

    test('同 key 并发只执行一次 refresh', () async {
      var calls = 0;
      final gate = Completer<String>();

      final first = coordinator.run(
        key: 'rss',
        force: true,
        lastRefreshedAt: null,
        throttleWindow: const Duration(minutes: 10),
        refresh: () {
          calls++;
          return gate.future;
        },
      );
      final second = coordinator.run(
        key: 'rss',
        force: false,
        lastRefreshedAt: now,
        throttleWindow: const Duration(minutes: 10),
        refresh: () async {
          calls++;
          return 'duplicate';
        },
      );

      gate.complete('fresh');
      final results = await Future.wait([first, second]);

      expect(calls, 1);
      expect(results.map((r) => (r as RefreshCompleted<String>).result), [
        'fresh',
        'fresh',
      ]);
    });

    test('不同 key 可并发刷新', () async {
      var calls = 0;

      final results = await Future.wait([
        coordinator.run(
          key: 'rss-a',
          force: true,
          lastRefreshedAt: null,
          throttleWindow: const Duration(minutes: 10),
          refresh: () async {
            calls++;
            return 'a';
          },
        ),
        coordinator.run(
          key: 'rss-b',
          force: true,
          lastRefreshedAt: null,
          throttleWindow: const Duration(minutes: 10),
          refresh: () async {
            calls++;
            return 'b';
          },
        ),
      ]);

      expect(calls, 2);
      expect(results.map((r) => (r as RefreshCompleted<String>).result), [
        'a',
        'b',
      ]);
    });

    test('refresh 抛错后会清理 inflight，后续可重试', () async {
      var calls = 0;

      Future<String> refresh() async {
        calls++;
        if (calls == 1) throw StateError('boom');
        return 'fresh';
      }

      await expectLater(
        coordinator.run(
          key: 'rss',
          force: true,
          lastRefreshedAt: null,
          throttleWindow: const Duration(minutes: 10),
          refresh: refresh,
        ),
        throwsA(isA<StateError>()),
      );

      final result = await coordinator.run(
        key: 'rss',
        force: true,
        lastRefreshedAt: null,
        throttleWindow: const Duration(minutes: 10),
        refresh: refresh,
      );

      expect(calls, 2);
      expect((result as RefreshCompleted<String>).result, 'fresh');
    });

    test('一小时窗口可用于版本检查节流', () async {
      var calls = 0;
      final result = await coordinator.run(
        key: 'app-update',
        force: false,
        lastRefreshedAt: now.subtract(const Duration(minutes: 59)),
        throttleWindow: const Duration(hours: 1),
        refresh: () async {
          calls++;
          return 'fresh';
        },
      );

      expect(result, isA<RefreshThrottled<String>>());
      expect(calls, 0);
    });
  });
}
