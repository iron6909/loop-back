/// 下载源回落：镜像「确实没有这个资源」时用上游重试一次，其余失败不回落。
///
/// 背景：中国区默认走 `hf-mirror.com`。镜像可能没同步某个 model revision
/// （404/410）或自身故障（5xx），这时上游是可用且内容相同的替代路径；反之，
/// 超时/连接失败/读中断属于网络波动，上游在中国区本就不通，回落只会让用户多等
/// 一次超时，因此**只有确定性的服务端拒绝**才回落。
library;

import 'package:dio/dio.dart';

import '../app_logger.dart';
import '../asr/asr_model_catalog.dart' show AsrDownloadSource;
import '../reliable_http_downloader.dart';

/// 以 [source] 执行 [run]；若镜像确定性地缺少资源，则改用上游再执行一次。
///
/// [run] 收到本次实际使用的来源，调用方需用它构造下载地址。回调被调用两次是
/// 预期行为（第二次为上游），因此 [run] 必须是可重入的：每次调用都从 staging 重建。
Future<T> withUpstreamFallback<T>({
  required String logTag,
  required AsrDownloadSource source,
  required Future<T> Function(AsrDownloadSource source) run,
}) async {
  if (source != AsrDownloadSource.huggingFaceMirror) {
    return run(source);
  }
  try {
    return await run(source);
  } on ReliableDownloadException catch (error) {
    if (!shouldFallBackToUpstream(error)) rethrow;
    AppLogger.log(
      logTag,
      '镜像缺少资源或服务异常 statusCode=${error.statusCode}，'
      '回退到上游重试一次',
    );
    return run(AsrDownloadSource.huggingFace);
  } on DioException catch (error) {
    // 安装器在少数路径上会直接抛 Dio 异常（如取消之外的适配器失败）。
    final status = error.response?.statusCode;
    if (status == null || !_isFallbackStatus(status)) rethrow;
    AppLogger.log(
      logTag,
      '镜像缺少资源或服务异常 statusCode=$status，回退到上游重试一次',
    );
    return run(AsrDownloadSource.huggingFace);
  }
}

/// 该失败是否属于「镜像取舍问题」（可以安全回落到上游）。
///
/// 只认确定性状态码：资源不存在（404/410）与镜像自身服务端错误（5xx）。
/// 超时、DNS/TLS/连接失败、读中断、取消一律不回落——它们是本地网络环境问题，
/// 中国区切到上游只会更差。
bool shouldFallBackToUpstream(ReliableDownloadException error) {
  if (error.kind != ReliableDownloadFailure.httpStatus) return false;
  final status = error.statusCode;
  return status != null && _isFallbackStatus(status);
}

bool _isFallbackStatus(int status) =>
    status == 404 || status == 410 || (status >= 500 && status < 600);
