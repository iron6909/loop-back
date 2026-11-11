/// 启动数据 gate 等待期间的品牌过渡页。
///
/// 此组件只依赖系统明暗模式，不读取业务 Provider，确保数据库尚未安全可读时
/// 不会提前创建业务导航树或触发数据查询。
library;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 原生与 Flutter 启动页共用的 Logo 源资源。
const _startupLogoAsset = 'assets/icon/app-icon.svg';

/// 保持与 Android/iOS 原生启动页一致的视觉尺寸。
const _startupLogoSize = 96.0;

/// 简洁的 Flutter 品牌启动页。
class StartupSplashScreen extends StatelessWidget {
  const StartupSplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // 启动页需与原生 Launch Screen 同步遵循系统主题；应用保存的主题偏好
    // 在真实 MaterialApp 页面创建后继续按原有逻辑生效。
    final brightness = MediaQuery.platformBrightnessOf(context);
    final backgroundColor = brightness == Brightness.dark
        ? const Color(0xFF000000)
        : const Color(0xFFF5F6FA);

    return ColoredBox(
      key: const ValueKey('startup-splash-background'),
      color: backgroundColor,
      child: Center(
        child: SvgPicture.asset(
          _startupLogoAsset,
          key: const ValueKey('startup-splash-logo'),
          width: _startupLogoSize,
          height: _startupLogoSize,
          semanticsLabel: 'LoopBack',
        ),
      ),
    );
  }
}
