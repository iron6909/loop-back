import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android 只保留启动入口，不注册已停用的登录和支付深链', () async {
    final content = await File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsString();

    expect(content, isNot(contains('android:autoVerify="true"')));
    expect(content, isNot(contains('android:host="echo-loop.top"')));
    expect(content, isNot(contains('android:host="www.echo-loop.top"')));
    expect(content, isNot(contains('android:scheme="echo-loop"')));
    expect(content, contains('android.intent.category.LAUNCHER'));
    expect(content, contains('android:name="flutter_deeplinking_enabled"'));
    expect(content, contains('android:value="false"'));
  });

  test('iOS 不注册支付回流 Scheme，同时保留文件关联', () async {
    final content = await File('ios/Runner/Info.plist').readAsString();

    expect(content, isNot(contains('<key>CFBundleURLTypes</key>')));
    expect(content, contains('<key>CFBundleDocumentTypes</key>'));
  });

  test('iOS 不再声明登录域名验证和 Apple 登录权限', () async {
    final content = await File('ios/Runner/Runner.entitlements').readAsString();

    expect(content, isNot(contains('com.apple.developer.associated-domains')));
    expect(content, isNot(contains('com.apple.developer.applesignin')));
  });

  test('macOS 不注册支付回流 Scheme，同时保留文件关联', () async {
    final content = await File('macos/Runner/Info.plist').readAsString();

    expect(content, isNot(contains('<key>CFBundleURLTypes</key>')));
    expect(content, contains('<key>CFBundleDocumentTypes</key>'));
  });

  for (final config in ['DebugProfile', 'Release']) {
    test('macOS $config 移除 Apple 登录权限并保留本机功能权限', () async {
      final content = await File(
        'macos/Runner/$config.entitlements',
      ).readAsString();

      expect(content, isNot(contains('com.apple.developer.applesignin')));
      expect(content, contains('com.apple.security.network.client'));
      expect(content, contains('com.apple.security.device.audio-input'));
      expect(
        content,
        contains('com.apple.security.files.user-selected.read-write'),
      );
      expect(content, contains('keychain-access-groups'));
    });
  }
}
