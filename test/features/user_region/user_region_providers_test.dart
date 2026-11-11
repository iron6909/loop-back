import 'dart:async';

import 'package:loop_back/features/user_region/user_region.dart';
import 'package:loop_back/features/remote_config/remote_config.dart';
import 'package:loop_back/features/user_region/user_region_bootstrapper.dart';
import 'package:loop_back/features/user_region/user_region_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only the system country code CN is China', () {
    expect(isChinaSystemRegion('CN'), isTrue);
    expect(isChinaSystemRegion(' cn '), isTrue);
    expect(isChinaSystemRegion('US'), isFalse);
    expect(isChinaSystemRegion('CHN'), isFalse);
    expect(isChinaSystemRegion('zh'), isFalse);
    expect(isChinaSystemRegion(null), isFalse);
    expect(isChinaSystemRegion(''), isFalse);
  });

  test('isChinaUserProvider reads the system Region country code', () {
    final chinaContainer = _containerWithPendingBootstrap(() => 'CN');
    addTearDown(chinaContainer.dispose);

    expect(chinaContainer.read(isChinaUserProvider), isTrue);
  });

  test('已解析的 Config 地区是 isChinaUserProvider 的唯一结果来源', () async {
    final container = ProviderContainer(
      overrides: [
        userRegionDeviceCountryCodeProvider.overrideWithValue(() => 'CN'),
        userRegionBootstrapProvider.overrideWith(
          (ref) async => const UserRegionBootstrapResult(
            isChinaUser: false,
            source: UserRegionDecisionSource.remoteConfig,
            remoteConfig: RemoteConfig.defaults,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(userRegionBootstrapProvider.future);

    expect(container.read(isChinaUserProvider), isFalse);
  });

  test('unknown or non-China system Region selects global', () {
    for (final countryCode in <String?>[null, '', 'US', 'CHN']) {
      final container = _containerWithPendingBootstrap(() => countryCode);
      expect(container.read(isChinaUserProvider), isFalse);
      container.dispose();
    }
  });

  test('a failed system Region read defaults to global', () {
    final container = _containerWithPendingBootstrap(
      () => throw StateError('locale unavailable'),
    );
    addTearDown(container.dispose);

    expect(container.read(isChinaUserProvider), isFalse);
  });
}

ProviderContainer _containerWithPendingBootstrap(
  String? Function() readCountryCode,
) {
  final bootstrapGate = Completer<UserRegionBootstrapResult>();
  return ProviderContainer(
    overrides: [
      userRegionDeviceCountryCodeProvider.overrideWithValue(readCountryCode),
      userRegionBootstrapProvider.overrideWith((ref) => bootstrapGate.future),
    ],
  );
}
