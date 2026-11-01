/// 供应商配置指纹与 AI 缓存类型构造
///
/// 缓存隔离靠 `SentenceAiCacheDao.type` 前缀实现，**不改 schema、不迁移数据**：
/// 旧后端写入的行保留原 `type`，新键自然不再命中，既不误用旧结果也不删用户数据。
///
/// API Key 刻意**不参与**指纹：换 Key 不改变模型与提示词，已有结果仍然有效；
/// 同时避免把凭据材料带进任何键（键会落库、进日志、进备份）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 计算配置指纹：`sha256("<baseUrl>|<model>|<promptVersion>")` 的前 16 位十六进制。
///
/// 16 位（64 bit）足以区分用户实际会配置的组合，同时让 `type` 保持可读长度。
String configFingerprint({
  required String baseUrl,
  required String model,
  required String promptVersion,
}) {
  final material = '$baseUrl|$model|$promptVersion';
  final digest = sha256.convert(utf8.encode(material)).toString();
  return digest.substring(0, 16);
}

/// 构造缓存类型：`<feature>[:<targetLanguage>]:<fingerprint>`。
///
/// [feature] 沿用各功能既有的缓存类型前缀（如 `translation_v2`、`sense_groups`）；
/// [targetLanguage] 为空或空白时不产生空段，避免出现 `feature::fingerprint`。
String cacheType({
  required String feature,
  required String fingerprint,
  String? targetLanguage,
}) {
  final language = targetLanguage?.trim() ?? '';
  if (language.isEmpty) return '$feature:$fingerprint';
  return '$feature:$language:$fingerprint';
}
