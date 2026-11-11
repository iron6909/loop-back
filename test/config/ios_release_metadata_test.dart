import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS Info.plist 默认显示名使用 LoopBack', () async {
    final content = await File('ios/Runner/Info.plist').readAsString();

    expect(content, contains('<key>CFBundleDisplayName</key>'));
    expect(content, contains('<string>LoopBack</string>'));
    expect(content, isNot(contains('<string>Fluency</string>')));
  });

  test('iOS 桌面名称支持中英文本地化', () async {
    final english = await File(
      'ios/Runner/en.lproj/InfoPlist.strings',
    ).readAsString();
    final chinese = await File(
      'ios/Runner/zh-Hans.lproj/InfoPlist.strings',
    ).readAsString();

    expect(english, contains('"CFBundleName" = "LoopBack";'));
    expect(chinese, contains('"CFBundleName" = "LoopBack";'));
  });

  test('iOS 字幕文档类型声明了 LSHandlerRank', () async {
    final content = await File('ios/Runner/Info.plist').readAsString();
    final subtitleDocumentTypes = RegExp(
      r'<dict>\s*<key>CFBundleTypeName</key>\s*<string>(SubRip Subtitle|WebVTT Subtitle|LRC Lyrics)</string>[\s\S]*?<key>LSHandlerRank</key>\s*<string>Alternate</string>',
    ).allMatches(content);

    expect(subtitleDocumentTypes.length, 3);
    expect(content, contains('<string>SubRip Subtitle</string>'));
    expect(content, contains('<string>WebVTT Subtitle</string>'));
    expect(content, contains('<string>LRC Lyrics</string>'));
    expect(content, contains('<string>top.loop-back.lrc-lyrics</string>'));
  });
}
