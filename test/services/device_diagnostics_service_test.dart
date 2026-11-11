import 'package:loop_back/services/device_diagnostics_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = DeviceDiagnosticsService.channel;

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'LoopBack',
      packageName: 'app.loopback',
      version: '1.2.3',
      buildNumber: '45',
      buildSignature: '',
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('格式化原生设备信息与 Dart 环境信息', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getDeviceInfo');
          return <String, Object?>{
            'manufacturer': 'Apple',
            'model': 'iPhone16,2',
            'systemName': 'iOS',
            'systemVersion': '18.5',
            'supportedAbis': <String>['arm64-v8a', 'armeabi-v7a'],
          };
        });

    late BuildContext capturedContext;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en', 'US'),
        home: Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final line = await const DeviceDiagnosticsService().buildLogLine(
      capturedContext,
    );

    expect(line, contains('app=1.2.3+45'));
    expect(line, contains('locale=en-US'));
    expect(line, contains('manufacturer=Apple'));
    expect(line, contains('model=iPhone16,2'));
    expect(line, contains('systemVersion=18.5'));
    expect(line, contains('supportedAbis=arm64-v8a,armeabi-v7a'));
  });

  testWidgets('原生通道失败时降级输出 Dart 侧环境信息', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'missing', message: 'not available');
        });

    late BuildContext capturedContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final line = await const DeviceDiagnosticsService().buildLogLine(
      capturedContext,
    );

    expect(line, contains('app=1.2.3+45'));
    expect(line, contains('nativeError='));
    expect(line, contains('not available'));
  });
}
