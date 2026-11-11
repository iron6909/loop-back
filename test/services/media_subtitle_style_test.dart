import 'package:loop_back/services/media_subtitle_style.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('手机小窗视频字幕字号保持常规下限', () {
    final style = MediaSubtitleStyle.forViewport(const Size(390, 219));

    expect(style.fontSize, 12);
    expect(style.horizontalPadding, closeTo(9.8, 0.1));
    expect(style.bottomPadding, 10);
  });

  test('截图尺寸视频字幕字号保持在正常阅读范围', () {
    final style = MediaSubtitleStyle.forViewport(const Size(810, 462));

    expect(style.fontSize, closeTo(16.2, 0.1));
    expect(style.horizontalPadding, closeTo(20.3, 0.1));
    expect(style.bottomPadding, closeTo(20.8, 0.1));
  });

  test('大画面视频字幕字号有上限', () {
    final style = MediaSubtitleStyle.forViewport(const Size(1920, 1080));

    expect(style.fontSize, 24);
    expect(style.horizontalPadding, 24);
    expect(style.bottomPadding, 28);
  });
}
