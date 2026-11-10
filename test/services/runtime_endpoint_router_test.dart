import 'package:echo_loop/config/api_config.dart'
    show apiBaseUrl, globalApiBaseUrl;
import 'package:echo_loop/config/regional_service_endpoints.dart';
import 'package:echo_loop/services/runtime_endpoint_router.dart';
import 'package:flutter_test/flutter_test.dart';

const _expectedChinaApiBaseUrl = String.fromEnvironment(
  'API_CHINA_BASE_URL',
  defaultValue: 'https://www.echo-loop.cn',
);
const _expectedGlobalApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://www.echo-loop.top',
);

const _testEndpoints = RegionalServiceEndpoints(
  globalApiBaseUrl: 'https://global-api.example',
  chinaApiBaseUrl: 'https://china-api.example',
);

void main() {
  test('endpoint registry contains configured global and China API URLs', () {
    expect(globalApiBaseUrl, _expectedGlobalApiBaseUrl);
    expect(chinaApiBaseUrl, _expectedChinaApiBaseUrl);
    expect(
      regionalServiceEndpoints.apiBaseUrlFor(ServiceEndpointRegion.global),
      apiBaseUrl,
    );
    expect(
      regionalServiceEndpoints.apiBaseUrlFor(ServiceEndpointRegion.china),
      _expectedChinaApiBaseUrl,
    );
  });

  test('runtime router retains configured China API endpoint', () {
    expect(runtimeEndpointRouter.apiBaseUrl, apiBaseUrl);
    expect(
      runtimeEndpointRouter.endpoints.apiBaseUrlFor(
        ServiceEndpointRegion.china,
      ),
      _expectedChinaApiBaseUrl,
    );
  });

  test('China system region immediately selects China API', () {
    final router = RuntimeEndpointRouter(endpoints: _testEndpoints)
      ..updateFromUserRegion(isChinaUser: true);

    expect(router.isChinaUser, isTrue);
    expect(router.apiRegion, ServiceEndpointRegion.china);
    expect(router.apiBaseUrl, 'https://china-api.example');
    expect(router.apiUri('/api/v1/client/config').host, 'china-api.example');
  });

  test('non-China users select the global API endpoint', () {
    final router = RuntimeEndpointRouter(endpoints: _testEndpoints)
      ..updateFromUserRegion(isChinaUser: false);

    expect(router.isChinaUser, isFalse);
    expect(router.apiRegion, ServiceEndpointRegion.global);
    expect(router.apiUri('/health').host, 'global-api.example');
  });

  test('a region change immediately switches API', () {
    final router = RuntimeEndpointRouter(endpoints: _testEndpoints)
      ..updateFromUserRegion(isChinaUser: true);
    expect(router.apiRegion, ServiceEndpointRegion.china);

    router.updateFromUserRegion(isChinaUser: false);

    expect(router.isChinaUser, isFalse);
    expect(router.apiRegion, ServiceEndpointRegion.global);
    expect(router.apiBaseUrl, 'https://global-api.example');
  });

  test('missing selected China API endpoint reports configuration error', () {
    const endpointsWithoutChina = RegionalServiceEndpoints(
      globalApiBaseUrl: 'https://global-api.example',
      chinaApiBaseUrl: '',
    );
    final router = RuntimeEndpointRouter(endpoints: endpointsWithoutChina)
      ..updateFromUserRegion(isChinaUser: true);

    expect(() => router.apiBaseUrl, throwsA(isA<StateError>()));
    expect(() => router.apiUri('/health'), throwsA(isA<StateError>()));
  });
}
