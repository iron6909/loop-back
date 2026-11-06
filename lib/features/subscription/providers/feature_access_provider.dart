/// 查询 AI 能力的本机访问策略。
///
/// 登录、会员与后端配额门控已移除，能力一律由本机
/// [FreeAllowancePolicy] 决定（当前策略全部放行），不再读取认证或权益状态。
/// 供应商侧的真实额度限制以请求错误形式呈现，不在此处预判。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart' show Ref;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/premium_feature.dart';
import '../services/free_allowance_policy.dart';

part 'feature_access_provider.g.dart';

/// 某 [feature] 当前是否对用户可用。
@riverpod
bool featureAccess(Ref ref, PremiumFeature feature) {
  return ref.watch(freeAllowancePolicyProvider).allows(feature);
}
