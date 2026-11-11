/// 品牌启动页视觉回归测试。
library;

import 'package:loop_back/widgets/startup_splash_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StartupSplashScreen', () {
    testWidgets('亮色系统中居中显示品牌 Logo，且不显示加载指示器', (tester) async {
      await tester.pumpWidget(_host(Brightness.light));

      final background = tester.widget<ColoredBox>(
        find.byKey(const ValueKey('startup-splash-background')),
      );
      final logo = tester.widget<SvgPicture>(
        find.byKey(const ValueKey('startup-splash-logo')),
      );

      expect(background.color, const Color(0xFFF5F6FA));
      expect(logo.width, 96);
      expect(logo.height, 96);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.getCenter(find.byKey(const ValueKey('startup-splash-logo'))),
        tester.getCenter(
          find.byKey(const ValueKey('startup-splash-background')),
        ),
      );
    });

    testWidgets('暗色系统使用纯黑背景', (tester) async {
      await tester.pumpWidget(_host(Brightness.dark));

      final background = tester.widget<ColoredBox>(
        find.byKey(const ValueKey('startup-splash-background')),
      );

      expect(background.color, const Color(0xFF000000));
    });
  });
}

Widget _host(Brightness brightness) {
  return MediaQuery(
    data: MediaQueryData(platformBrightness: brightness),
    child: const Directionality(
      textDirection: TextDirection.ltr,
      child: StartupSplashScreen(),
    ),
  );
}
