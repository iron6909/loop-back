/// 供应商直连的 HTTP 客户端与错误映射
///
/// 与后端客户端刻意隔离：不挂 Supabase token、平台/渠道头、权益拦截器，也不经
/// 区域路由——它只认用户在设置页填写的 Base URL 与 Key。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import 'provider_config.dart';

/// 供应商失败的领域分类，UI 据此给出可操作提示。
enum ProviderErrorKind {
  /// 400/422：供应商拒绝请求参数或输出格式。
  invalidRequest,

  /// 401：Key 无效或未授权。
  unauthorized,

  /// 402：供应商账户余额或套餐不足。
  insufficientBalance,

  /// 404：Base URL 或模型不存在。
  notFound,

  /// 429：限流或额度耗尽。
  rateLimited,

  /// 5xx：重试一次后仍失败。
  serverError,

  /// 连接或接收超时。
  timeout,

  /// 其他网络错误。
  network,

  /// 用户取消。
  cancelled,

  /// 2xx 但响应不是 JSON 对象。
  invalidResponse,
}

/// 供应商调用失败。[toString] 只含分类与状态码，不含请求头或正文。
class ProviderHttpException implements Exception {
  const ProviderHttpException(this.kind, {this.statusCode, this.body});

  final ProviderErrorKind kind;
  final int? statusCode;

  /// 非 2xx 的原始正文（已截断），仅供回落判定；不写入日志。
  final String? body;

  @override
  String toString() =>
      'ProviderHttpException(${kind.name}'
      '${statusCode == null ? '' : ', status=$statusCode'})';
}

/// 结构化与聊天共用的供应商客户端。
class ProviderHttpClient {
  ProviderHttpClient({
    required ProviderConfig config,
    required String apiKey,
    Dio? dio,
    String appVersion = '',
  }) : _apiKey = apiKey,
       _endpoint = _buildEndpoint(config.baseUrl),
       _isOpenCodeHost = Uri.parse(config.baseUrl).host == 'opencode.ai',
       _sessionId = const Uuid().v4(),
       _appVersion = appVersion,
       _dio = dio ?? Dio() {
    if (baseUrlError(config.baseUrl) != null) {
      throw ArgumentError('供应商地址无效');
    }
    _dio.options
      ..connectTimeout = const Duration(seconds: 15)
      ..receiveTimeout = const Duration(seconds: 120)
      ..followRedirects = false
      ..headers.clear()
      ..validateStatus = (_) => true;
  }

  final Dio _dio;
  final String _apiKey;
  final String _endpoint;
  final bool _isOpenCodeHost;
  final String _sessionId;
  final String _appVersion;

  /// 基址末尾的斜杠不产生双斜杠；**不**自动补 `/v1`，用户填什么就用什么。
  static String _buildEndpoint(String baseUrl) {
    final trimmed = baseUrl.replaceAll(RegExp(r'/+$'), '');
    return '$trimmed/chat/completions';
  }

  /// 每次请求都重新构造头部，避免被 Dio 的默认头污染。
  Map<String, String> get _headers => {
    'Authorization': 'Bearer $_apiKey',
    'Content-Type': 'application/json',
    'User-Agent': _appVersion.isEmpty ? 'EchoLoop' : 'EchoLoop/$_appVersion',
    // OpenCode Go 要求稳定的会话标识以识别同一客户端；其他主机不发送。
    if (_isOpenCodeHost) 'x-opencode-session': _sessionId,
  };

  /// 发送 Chat Completions 请求并返回已解码的响应对象。
  ///
  /// 5xx 重试一次；4xx、超时与网络错误不重试。正文解析交给调用方，因为不同功能
  /// 需要看到原始内容（例如 `finish_reason` 与校验失败分类）。
  Future<Map<String, dynamic>> postChatCompletions(
    Object body, {
    CancelToken? cancelToken,
  }) async {
    if (_apiKey.trim().isEmpty || RegExp(r'[\r\n]').hasMatch(_apiKey)) {
      throw const ProviderHttpException(ProviderErrorKind.unauthorized);
    }
    for (var attempt = 0; ; attempt++) {
      try {
        final response = await _dio.post<Object?>(
          _endpoint,
          data: body,
          options: Options(headers: _headers),
          cancelToken: cancelToken,
        );
        final status = response.statusCode ?? 0;
        if (status >= 200 && status < 300) return _decode(response.data);

        final kind = _mapStatus(status);
        if (kind == ProviderErrorKind.serverError && attempt == 0) continue;
        throw ProviderHttpException(
          kind,
          statusCode: status,
          body: _bodyText(response.data),
        );
      } on DioException catch (error) {
        throw _mapDioException(error);
      }
    }
  }

  /// 2xx 正文必须是 JSON 对象；数组或标量按无效响应处理。
  Map<String, dynamic> _decode(Object? data) {
    final decoded = switch (data) {
      Map<String, dynamic>() => data,
      String() when data.trim().isNotEmpty => _tryDecode(data),
      _ => null,
    };
    if (decoded == null) {
      throw const ProviderHttpException(ProviderErrorKind.invalidResponse);
    }
    return decoded;
  }

  Map<String, dynamic>? _tryDecode(String raw) {
    try {
      final value = jsonDecode(raw);
      return value is Map<String, dynamic> ? value : null;
    } on FormatException {
      return null;
    }
  }

  ProviderErrorKind _mapStatus(int status) => switch (status) {
    400 || 422 => ProviderErrorKind.invalidRequest,
    401 => ProviderErrorKind.unauthorized,
    402 => ProviderErrorKind.insufficientBalance,
    404 => ProviderErrorKind.notFound,
    429 => ProviderErrorKind.rateLimited,
    >= 500 => ProviderErrorKind.serverError,
    _ => ProviderErrorKind.network,
  };

  /// 流式请求：返回原始字节流，SSE 解析交给调用方。
  ///
  /// 与 [postChatCompletions] 共用地址拼接、头部与空 Key 校验；不重试，
  /// 避免半截流被重发后与已展示文本拼接出错。
  Future<Stream<Uint8List>> postChatCompletionsStream(
    Object body, {
    CancelToken? cancelToken,
  }) async {
    if (_apiKey.trim().isEmpty || RegExp(r'[\r\n]').hasMatch(_apiKey)) {
      throw const ProviderHttpException(ProviderErrorKind.unauthorized);
    }
    try {
      final response = await _dio.post<ResponseBody>(
        _endpoint,
        data: body,
        options: Options(headers: _headers, responseType: ResponseType.stream),
        cancelToken: cancelToken,
      );
      final status = response.statusCode ?? 0;
      final stream = response.data?.stream;
      if (status < 200 || status >= 300 || stream == null) {
        throw ProviderHttpException(_mapStatus(status), statusCode: status);
      }
      // 响应头返回后的超时也从这里映射，保留此前已经产出的字节。
      return stream.handleError((Object error) {
        if (error is DioException) throw _mapDioException(error);
        throw error;
      });
    } on DioException catch (error) {
      throw _mapDioException(error);
    }
  }

  /// 用量类只读 GET：只接受调用方用**已配置主机**拼出的绝对地址。
  ///
  /// 与聊天请求共用超时、空 Key 与重定向限制；不重试，用量失败不影响推理。
  Future<Map<String, dynamic>> getJson(
    Uri uri, {
    CancelToken? cancelToken,
  }) async {
    if (_apiKey.trim().isEmpty || RegExp(r'[\r\n]').hasMatch(_apiKey)) {
      throw const ProviderHttpException(ProviderErrorKind.unauthorized);
    }
    if (uri.origin != Uri.parse(_endpoint).origin) {
      throw ArgumentError('用量查询不可跨供应商发送凭据');
    }
    try {
      final response = await _dio.get<Object?>(
        uri.toString(),
        options: Options(headers: _headers),
        cancelToken: cancelToken,
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        throw ProviderHttpException(
          _mapStatus(status),
          statusCode: status,
          body: _bodyText(response.data),
        );
      }
      return _decode(response.data);
    } on DioException catch (error) {
      throw _mapDioException(error);
    }
  }

  /// 取错误体文本供回落判定；只保留前 2 KB，避免把大正文带进内存或日志。
  String? _bodyText(Object? data) {
    final text = switch (data) {
      String() => data,
      Map<String, dynamic>() => jsonEncode(data),
      _ => null,
    };
    if (text == null || text.isEmpty) return null;
    return text.length <= 2048 ? text : text.substring(0, 2048);
  }

  ProviderHttpException _mapDioException(DioException error) {
    final kind = switch (error.type) {
      DioExceptionType.cancel => ProviderErrorKind.cancelled,
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => ProviderErrorKind.timeout,
      _ => ProviderErrorKind.network,
    };
    return ProviderHttpException(kind);
  }

  /// 释放底层连接池。
  void dispose() => _dio.close();
}
