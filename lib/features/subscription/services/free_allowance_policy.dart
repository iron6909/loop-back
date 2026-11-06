/// 本机功能的访问策略；用户供应商的余额与限流由对应服务返回。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/premium_feature.dart';

/// 本机功能是否允许使用，不读取旧账户或订阅权益。
abstract class FreeAllowancePolicy {
  bool allows(PremiumFeature feature);
}

/// 当前本机功能全部开放。
class AlwaysAllowPolicy implements FreeAllowancePolicy {
  const AlwaysAllowPolicy();

  @override
  bool allows(PremiumFeature feature) => true;
}

final freeAllowancePolicyProvider = Provider<FreeAllowancePolicy>((ref) {
  return const AlwaysAllowPolicy();
});
