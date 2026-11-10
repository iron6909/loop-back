import '../config/regional_service_endpoints.dart';
import 'app_logger.dart';

/// 按本次启动最终地区在全球和中国 API 之间固定选择一个区域。
class RuntimeEndpointRouter {
  RuntimeEndpointRouter({required this.endpoints});

  final RegionalServiceEndpoints endpoints;

  bool _isChinaUser = false;

  /// 当前地区判定快照。
  bool get isChinaUser => _isChinaUser;

  /// 当前 API 区域选择。
  ServiceEndpointRegion get apiRegion => _selectedRegion;

  ServiceEndpointRegion get _selectedRegion =>
      _isChinaUser ? ServiceEndpointRegion.china : ServiceEndpointRegion.global;

  /// 当前所选区域的 API 地址；未配置时明确报错，不访问另一区域。
  String get apiBaseUrl => _requiredEndpoint(
    endpoints.apiBaseUrlFor(_selectedRegion),
    service: 'API',
  );

  Uri apiUri(String path) => _resolvePath(apiBaseUrl, path);

  /// 启动地区决策完成后固定本进程的 API 区域。
  void updateFromUserRegion({required bool isChinaUser}) {
    _isChinaUser = isChinaUser;
    final region = _selectedRegion;
    AppLogger.log(
      'EndpointRouter',
      'userRegion china=$isChinaUser selected=${region.name} '
          'api=${_endpointLabel(endpoints.apiBaseUrlFor(region))}',
    );
  }

  String _requiredEndpoint(String? endpoint, {required String service}) {
    if (endpoint != null) return endpoint;
    throw StateError(
      'No $service endpoint is configured for ${_selectedRegion.name}',
    );
  }

  String _endpointLabel(String? baseUrl) {
    if (baseUrl == null) return 'unconfigured';
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return 'invalid';
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  }

  Uri _resolvePath(String baseUrl, String path) {
    final relativePath = path.startsWith('/') ? path.substring(1) : path;
    return Uri.parse('$baseUrl/').resolve(relativePath);
  }
}

/// 所有构建模式共用编译期端点配置，具体区域由系统 Region 决定。
final runtimeEndpointRouter = RuntimeEndpointRouter(
  endpoints: regionalServiceEndpoints,
);
