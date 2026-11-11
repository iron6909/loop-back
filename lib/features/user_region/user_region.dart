/// 基于系统 Region 判断用户是否使用中国区服务。
library;

/// 地区枚举；去品牌化后不再关联任何远程服务端点，
/// 仅用于地区判定（analytics 等）与开发者覆盖。
enum AppRegion { china, global }

/// 系统 Region 国家码为 CN 时使用中国区服务，其余情况使用全球服务。
bool isChinaSystemRegion(String? countryCode) {
  return countryCode?.trim().toUpperCase() == 'CN';
}
