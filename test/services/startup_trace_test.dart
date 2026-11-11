import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/services/startup_trace.dart';

void main() {
  test('在日志 sink 就绪前缓冲事件，并按原顺序落盘', () {
    var elapsedMs = 0;
    var recordedAtMs = 1000;
    final messages = <String>[];
    final trace = StartupTrace(
      launchId: 'launch-a',
      elapsedMilliseconds: () => elapsedMs,
      recordedAtMilliseconds: () => recordedAtMs,
      logger: (_, message) => messages.add(message),
    );

    trace.mark('dart_main_enter');
    elapsedMs = 8;
    recordedAtMs = 1008;
    trace.mark('flutter_binding_ready');
    trace.attachLogger();
    elapsedMs = 12;
    recordedAtMs = 1012;
    trace.mark('run_app_invoked');

    expect(messages, hasLength(3));
    expect(
      messages[0],
      contains(
        'event=dart_main_enter launchId=launch-a recordedAtMs=1000 elapsedMs=0',
      ),
    );
    expect(
      messages[1],
      contains(
        'event=flutter_binding_ready launchId=launch-a recordedAtMs=1008 elapsedMs=8',
      ),
    );
    expect(
      messages[2],
      contains(
        'event=run_app_invoked launchId=launch-a recordedAtMs=1012 elapsedMs=12',
      ),
    );
  });

  test('成功与失败步骤都会记录耗时，失败仍原样抛出', () async {
    var elapsedMs = 10;
    final messages = <String>[];
    final trace = StartupTrace(
      launchId: 'launch-b',
      elapsedMilliseconds: () => elapsedMs,
      logger: (_, message) => messages.add(message),
    )..attachLogger();

    final result = await trace.run('async_step', () async {
      elapsedMs = 35;
      return 42;
    });
    expect(result, 42);
    expect(messages.join('\n'), contains('event=step_success'));
    expect(messages.join('\n'), contains('step=async_step durationMs=25'));

    await expectLater(
      trace.run<void>('failing_step', () async {
        elapsedMs = 50;
        throw StateError('failed');
      }),
      throwsA(isA<StateError>()),
    );
    expect(messages.join('\n'), contains('event=step_failure'));
    expect(messages.join('\n'), contains('step=failing_step durationMs=15'));
    expect(messages.join('\n'), contains('event=step_failure_stack'));
  });

  test('同步步骤的异常不被追踪器吞掉', () {
    final messages = <String>[];
    final trace = StartupTrace(
      launchId: 'launch-c',
      elapsedMilliseconds: () => 0,
      logger: (_, message) => messages.add(message),
    )..attachLogger();

    expect(
      () => trace.runSync<void>('sync_step', () => throw ArgumentError('bad')),
      throwsArgumentError,
    );
    expect(messages.join('\n'), contains('event=step_failure'));
  });
}
