import 'package:echo_loop/features/remote_config/remote_config.dart';
import 'package:echo_loop/features/remote_config/remote_config_providers.dart';
import 'package:echo_loop/features/remote_config/remote_config_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('配置恒为本地默认值，旧缓存与请求都不参与', () async {
    const service = RemoteConfigService();

    for (final config in [
      service.loadInitialFromCache(),
      await service.load(),
      await service.fetchRemote(),
      await service.fetchRemoteFromBaseUrl(
        'https://api.example',
        timeout: const Duration(seconds: 1),
      ),
    ]) {
      expect(config.isEnabled(RemoteFeature.aiChatAssistant), isTrue);
      expect(config.isEnabled(RemoteFeature.inAppReview), isFalse);
    }
    expect(service.lastFetchedAt, isNull);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(remoteFeatureEnabledProvider(RemoteFeature.aiChatAssistant)),
      isTrue,
    );
    // 刷新调用不改变状态，也不触网。
    await container.read(remoteConfigProvider.notifier).refreshIfStale(force: true);
    expect(
      container.read(remoteFeatureEnabledProvider(RemoteFeature.aiChatAssistant)),
      isTrue,
    );
  });
}
