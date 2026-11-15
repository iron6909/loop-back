/// 相对时间格式化工具
///
/// 基于 timeago 库，支持中英文自动切换。
library;

import 'package:flutter/widgets.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../l10n/app_localizations.dart';

/// 初始化 timeago 中文 locale（在 main() 中调用一次）
void initTimeago() {
  timeago.setLocaleMessages('zh', _ZhCnMessages());
  timeago.setLocaleMessages('en', _EnMessages());
}

/// 将 [dateTime] 格式化为相对时间（如"5分钟前"/"5 minutes ago"）
///
/// 自动根据当前 locale 切换语言。
String formatTimeAgo(BuildContext context, DateTime dateTime) {
  return timeago.format(
    dateTime,
    locale: Localizations.localeOf(context).languageCode,
  );
}

/// 将未来的 [dateTime] 格式化为相对时间（如“5分钟后”/“in 5 minutes”）。
///
/// 预定复习时间可能因设备时钟变化而已到期，此时仍按既有过去时间语义显示。
String formatTimeFromNow(BuildContext context, DateTime dateTime) {
  final now = DateTime.now();
  final difference = dateTime.difference(now);
  // 未来一分钟内直接显示秒数，避免模糊时间词与未来后缀组合。
  if (!difference.isNegative && difference < const Duration(minutes: 1)) {
    final seconds = difference.inSeconds;
    return AppLocalizations.of(context)!.timeFromNowSeconds(seconds);
  }

  return timeago.format(
    dateTime,
    locale: Localizations.localeOf(context).languageCode,
    allowFromNow: true,
  );
}

/// 根据复习设置展示答案页预览的固定下次复习间隔。
///
/// 收藏句与收藏词汇共用此函数。间隔在进入答案页时确定，背面重播、等待
/// 或页面重建都不能让评分栏显示成实时倒计时。
String? formatNextReviewTimeDetail(
  BuildContext context, {
  required bool showNextReviewTime,
  required Duration? interval,
}) {
  if (!showNextReviewTime || interval == null) return null;
  final reference = DateTime.utc(2000);
  final dueAt = reference.add(interval);
  final seconds = interval.inSeconds;
  if (interval < const Duration(minutes: 1)) {
    return AppLocalizations.of(context)!.timeFromNowSeconds(seconds);
  }
  return timeago.format(
    dueAt,
    clock: reference,
    locale: Localizations.localeOf(context).languageCode,
    allowFromNow: true,
  );
}

/// 简体中文 timeago 消息
class _ZhCnMessages implements timeago.LookupMessages {
  @override
  String prefixAgo() => '';
  @override
  String prefixFromNow() => '';
  @override
  String suffixAgo() => '前';
  @override
  String suffixFromNow() => '后';
  @override
  String lessThanOneMinute(int seconds) => '刚刚';
  @override
  String aboutAMinute(int minutes) => '1分钟';
  @override
  String minutes(int minutes) => '$minutes分钟';
  @override
  String aboutAnHour(int minutes) => '1小时';
  @override
  String hours(int hours) => '$hours小时';
  @override
  String aDay(int hours) => '1天';
  @override
  String days(int days) => '$days天';
  @override
  String aboutAMonth(int days) => '1个月';
  @override
  String months(int months) => '$months个月';
  @override
  String aboutAYear(int year) => '1年';
  @override
  String years(int years) => '$years年';
  @override
  String wordSeparator() => '';
}

/// 英文时间消息：未来时间使用更自然的 “in 5 minutes” 语序。
class _EnMessages implements timeago.LookupMessages {
  @override
  String prefixAgo() => '';
  @override
  String prefixFromNow() => 'in';
  @override
  String suffixAgo() => 'ago';
  @override
  String suffixFromNow() => '';
  @override
  String lessThanOneMinute(int seconds) => 'a moment';
  @override
  String aboutAMinute(int minutes) => 'a minute';
  @override
  String minutes(int minutes) => '$minutes minutes';
  @override
  String aboutAnHour(int minutes) => 'about an hour';
  @override
  String hours(int hours) => '$hours hours';
  @override
  String aDay(int hours) => 'a day';
  @override
  String days(int days) => '$days days';
  @override
  String aboutAMonth(int days) => 'about a month';
  @override
  String months(int months) => '$months months';
  @override
  String aboutAYear(int year) => 'about a year';
  @override
  String years(int years) => '$years years';
  @override
  String wordSeparator() => ' ';
}

/// 已完成大阶段标题文案。
///
/// 使用相对时间，但显式带上“完成于 / Completed”前缀，避免误读成逾期时间。
String formatCompletedStageTimeLabel(
  BuildContext context,
  DateTime completedAt,
) {
  final ago = formatTimeAgo(context, completedAt);
  final isZh = Localizations.localeOf(context).languageCode == 'zh';
  return isZh ? '完成于$ago' : 'Completed $ago';
}
