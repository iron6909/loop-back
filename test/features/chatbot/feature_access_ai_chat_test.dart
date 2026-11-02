/// PremiumFeature.aiChat 接入 featureAccessProvider 的回归。
///
/// 登录与会员门控已移除：聊天入口只受本机策略与供应商错误影响。
library;

import 'package:echo_loop/features/subscription/models/premium_feature.dart';
import 'package:echo_loop/features/subscription/providers/feature_access_provider.dart';
import 'package:echo_loop/features/subscription/services/free_allowance_policy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ProviderContainer makeContainer(FreeAllowancePolicy policy) {
    final container = ProviderContainer(
      overrides: [freeAllowancePolicyProvider.overrideWithValue(policy)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('现网策略下聊天入口放行', () {
    final c = makeContainer(const AlwaysAllowPolicy());
    expect(c.read(featureAccessProvider(PremiumFeature.aiChat)), isTrue);
  });

  test('策略拒绝时隐藏聊天入口', () {
    final c = makeContainer(_DenyPolicy());
    expect(c.read(featureAccessProvider(PremiumFeature.aiChat)), isFalse);
  });
}

class _DenyPolicy implements FreeAllowancePolicy {
  @override
  bool allows(PremiumFeature feature) => false;
}
