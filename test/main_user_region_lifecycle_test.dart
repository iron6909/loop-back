import 'package:loop_back/features/user_region/user_region_providers.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('resume does not change the process region snapshot', (
    tester,
  ) async {
    var systemCountryCode = 'CN';
    final container = ProviderContainer(
      overrides: [
        userRegionDeviceCountryCodeProvider.overrideWithValue(
          () => systemCountryCode,
        ),
      ],
    );
    addTearDown(container.dispose);

    final future = container.read(userRegionBootstrapProvider.future);
    await tester.pump();
    await tester.runAsync(() => future);

    expect(container.read(isChinaUserProvider), isTrue);

    systemCountryCode = 'US';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    // 地区在本进程启动时固定，resume 不重新判定。
    expect(container.read(isChinaUserProvider), isTrue);
    expect(tester.takeException(), isNull);

    // 清理测试应用首帧后安排的延迟任务。
    await tester.pump(const Duration(seconds: 6));
  });
}
