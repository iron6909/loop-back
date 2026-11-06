import 'package:echo_loop/features/subscription/models/premium_feature.dart';
import 'package:echo_loop/features/subscription/providers/feature_access_provider.dart';
import 'package:echo_loop/features/subscription/services/free_allowance_policy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _DenyPolicy implements FreeAllowancePolicy {
  const _DenyPolicy();
  @override
  bool allows(PremiumFeature feature) => false;
}

void main() {
  ProviderContainer makeContainer(FreeAllowancePolicy policy) {
    final container = ProviderContainer(
      overrides: [freeAllowancePolicyProvider.overrideWithValue(policy)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('默认策略放行，不需要登录或会员', () {
    final container = makeContainer(const AlwaysAllowPolicy());
    for (final feature in PremiumFeature.values) {
      expect(container.read(featureAccessProvider(feature)), isTrue);
    }
  });

  test('策略拒绝时锁定', () {
    final container = makeContainer(const _DenyPolicy());
    expect(
      container.read(featureAccessProvider(PremiumFeature.aiChat)),
      isFalse,
    );
  });
}
