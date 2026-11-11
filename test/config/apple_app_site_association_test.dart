import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AASA 文件使用新的 iOS Bundle ID', () async {
    final file = File('web/apple-app-site-association');
    final content = await file.readAsString();
    final json = jsonDecode(content) as Map<String, Object?>;
    final applinks = json['applinks'] as Map<String, Object?>;
    final details = applinks['details'] as List<Object?>;
    final firstDetail = details.first as Map<String, Object?>;
    final appIds = firstDetail['appIDs'] as List<Object?>;

    expect(appIds, contains('S8S968QAV3.top.loop-back'));
    expect(appIds, isNot(contains('S8S968QAV3.top.valuespot.fluency')));
  });
}
