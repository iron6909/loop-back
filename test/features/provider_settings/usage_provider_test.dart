/// 用量界面接线：配置切换丢弃旧数据，用量状态释放不关闭推理连接。
library;

import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:echo_loop/features/provider_settings/providers/usage_provider.dart';
import 'package:echo_loop/providers/provider_configuration_provider.dart';
import 'package:echo_loop/services/provider/provider_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../helpers/provider_fixture.dart';

void main() {
  late ProviderFixture fixture;
  setUp(() => fixture = ProviderFixture());
  tearDown(() => fixture.dispose());

  test('切换供应商时迟到的余额不会覆盖新状态', () async {
    await fixture.configure(
      config: const ProviderConfig(
        kind: ProviderKind.deepseek,
        baseUrl: 'https://api.deepseek.com',
        model: 'm',
      ),
    );
    final gate = Completer<ResponseBody>();
    fixture.adapter.replies.add((_) => gate.future);
    final arrived = fixture.adapter.arrived.stream.first;
    final previous = fixture.container.read(usageQueryProvider.future);
    await arrived;
    await fixture.configure();
    gate.complete(
      ResponseBody.fromString(
        jsonEncode({
          'balance_infos': [
            {'currency': 'USD', 'total_balance': '999'},
          ],
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    final current = await fixture.container.read(usageQueryProvider.future);
    await previous;
    expect(current.unsupported, isTrue);
    expect(current.hasData, isFalse);
    expect(
      fixture.container.read(usageQueryProvider).valueOrNull?.hasData,
      isFalse,
    );
  });

  test('刷新用量不会销毁共享推理客户端', () async {
    await fixture.configure();
    await fixture.container.read(usageQueryProvider.future);
    fixture.container.invalidate(usageQueryProvider);
    await fixture.container.read(usageQueryProvider.future);
    fixture.adapter.completion({'translation': 'still available'});
    final runtime = await fixture.container.read(
      providerConfigurationProvider.future,
    );
    final response = await runtime?.http.postChatCompletions({'model': 'm'});
    expect(response?['choices'], isNotEmpty);
  });
}
