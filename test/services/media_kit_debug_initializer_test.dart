import 'package:loop_back/services/media_kit_debug_initializer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('热重启旧引用先清 wakeup callback 再发送 quit', () {
    final calls = <String>[];
    final testCleaner = MediaKitHotRestartReferenceCleaner(
      clearWakeupCallback: (address) => calls.add('clear:$address'),
      quit: (address) => calls.add('quit:$address'),
    );

    testCleaner.clean([11, 22]);

    expect(calls, ['clear:11', 'clear:22', 'quit:11', 'quit:22']);
  });

  test('初始化成功后跳过后续调用', () {
    var calls = 0;
    final initializer = MediaKitInitializer(initialize: () => calls++);

    initializer.ensureInitialized();
    initializer.ensureInitialized();

    expect(calls, 1);
    expect(initializer.isInitialized, isTrue);
  });

  test('初始化失败后下一次调用会重试', () {
    var calls = 0;
    final initializer = MediaKitInitializer(
      initialize: () {
        calls++;
        if (calls == 1) throw StateError('first attempt fails');
      },
    );

    expect(initializer.ensureInitialized, throwsStateError);
    initializer.ensureInitialized();

    expect(calls, 2);
    expect(initializer.isInitialized, isTrue);
  });
}
