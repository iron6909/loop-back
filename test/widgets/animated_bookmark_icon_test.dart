/// AnimatedBookmarkIcon 的收藏颜色回归测试。
library;

import 'package:loop_back/theme/app_theme.dart';
import 'package:loop_back/widgets/animated_bookmark_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('已收藏状态默认使用统一收藏橙黄色', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: AnimatedBookmarkIcon(isSaved: true)),
      ),
    );

    final icon = tester.widget<Icon>(find.byIcon(Icons.bookmark));

    expect(icon.color, AppTheme.bookmarkColor);
  });
}
