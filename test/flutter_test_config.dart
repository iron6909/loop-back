/// Flutter 测试全局配置
///
/// 设置统一的测试窗口大小，避免布局溢出错误。
/// 注册 ShowcaseView 控制器，解决 GuideTarget 测试失败。
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:showcaseview/showcaseview.dart';

/// 测试窗口尺寸（模拟平板/手机横向尺寸）
const _kTestWindowSize = Size(1200, 800);

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  // 全局提供纯 Dart 的偏好实现，避免未显式注入 provider 的测试访问真实平台通道。
  SharedPreferences.setMockInitialValues({});
  // 原生 media_kit 依赖只在对应平台 runner 中存在；本地无原生框架时保留测试回退路径。
  try {
    MediaKit.ensureInitialized();
  } on Object {
    // 测试不依赖原生播放器时无需阻断整个测试进程。
  }

  // 设置测试窗口大小
  binding.window.physicalSizeTestValue = _kTestWindowSize;
  binding.window.devicePixelRatioTestValue = 1.0;

  // 注册 ShowcaseView 控制器（测试环境全局一次）
  // ignore: unused_local_variable
  final showcase = ShowcaseView.register();

  await testMain();
}
