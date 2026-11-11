import 'package:loop_back/features/remote_config/remote_config_dependencies.dart';
import 'package:loop_back/features/user_region/user_region_bootstrapper.dart';
import 'package:loop_back/features/user_region/user_region_override.dart';
import 'package:loop_back/features/user_region/user_region_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('覆盖值可保存读取，选回自动时清除', () async {
    SharedPreferences.setMockInitialValues({});
    const store = UserRegionOverrideStore();

    expect(await store.load(), UserRegionOverride.auto);
    await store.save(UserRegionOverride.china);
    expect(await store.load(), UserRegionOverride.china);
    await store.save(UserRegionOverride.auto);
    expect(await store.load(), UserRegionOverride.auto);
  });

  test('无效的已存值按自动处理', () async {
    SharedPreferences.setMockInitialValues({
      'developer_user_region_override': 'mars',
    });
    expect(
      await const UserRegionOverrideStore().load(),
      UserRegionOverride.auto,
    );
  });

  testWidgets('已保存的强制中国区让启动地区判定固定到中国区（不访问后端）', (tester) async {
    SharedPreferences.setMockInitialValues({
      'developer_user_region_override': 'china',
    });
    final container = ProviderContainer(
      overrides: [
        userRegionDeviceCountryCodeProvider.overrideWithValue(() => 'US'),
        remoteConfigServiceProvider.overrideWith(
          (ref) => throw StateError('地区判定不应请求配置接口'),
        ),
      ],
    );
    addTearDown(container.dispose);

    final future = container.read(userRegionBootstrapProvider.future);
    await tester.pump();
    final result = await tester.runAsync(() => future);

    expect(result?.source, UserRegionDecisionSource.developerOverride);
    expect(container.read(isChinaUserProvider), isTrue);
  });

  testWidgets('无覆盖时按系统 Region 固定，不请求配置接口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        userRegionDeviceCountryCodeProvider.overrideWithValue(() => 'CN'),
        remoteConfigServiceProvider.overrideWith(
          (ref) => throw StateError('地区判定不应请求配置接口'),
        ),
      ],
    );
    addTearDown(container.dispose);

    final future = container.read(userRegionBootstrapProvider.future);
    await tester.pump();
    final result = await tester.runAsync(() => future);

    expect(result?.source, UserRegionDecisionSource.systemFallback);
    expect(container.read(isChinaUserProvider), isTrue);
  });
}
