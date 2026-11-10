/// 通用下载失败归类。
///
/// 多个按需下载任务（离线 ASR 模型、本地 TTS 模型等）此前都直接把原始异常
/// `'$e'` 塞进状态展示给用户——用户只看到 `FileSystemException: ... errno = 28`
/// 这类技术细节，不知道究竟是空间不够还是网络问题。本模块把异常归类为少数几个
/// **确定**的原因（存储不足 / 网络 / 文件校验），无法确定时归为 [unknown]，由 UI
/// 映射为本地化文案：确定原因给明确指引，不确定则回退通用「下载失败，请重试」。
///
/// 原始异常仍应由调用方打日志（诊断用），不直接展示给用户。
library;

import 'dart:io' show FileSystemException;

import 'package:dio/dio.dart';

import '../reliable_http_downloader.dart';

/// 下载失败的归类原因。
enum DownloadFailureKind {
  /// 设备存储空间不足（errno 28 / No space left on device）。
  insufficientStorage,

  /// 网络错误（连接失败 / 超时 / 服务器错误等，取消除外）。
  network,

  /// 文件校验失败（整包 SHA 不匹配或解包后关键文件缺失，多为下载不完整/损坏）。
  verification,

  /// 原因不确定。
  unknown,
}

/// 把下载/安装过程抛出的异常 [error] 归类为 [DownloadFailureKind]。
///
/// 仅用于**失败**场景；取消（[DioExceptionType.cancel]）不是失败，由调用方在归类
/// 之前单独处理，不要传进来。
DownloadFailureKind classifyDownloadFailure(Object error) {
  // ReliableHttpDownloader 的结构化异常：优先按 kind 分类，kind 不够确定时
  // 递归看 cause（如底层 FileSystemException 的 errno 28），仍不确定才归为
  // unknown——不能直接退化到下面的通用分支，因为 ReliableDownloadException
  // 自身的 toString() 不含 cause 详情，字符串匹配分支会失效。
  if (error is ReliableDownloadException) {
    switch (error.kind) {
      case ReliableDownloadFailure.storage:
        return DownloadFailureKind.insufficientStorage;
      case ReliableDownloadFailure.integrity:
        return DownloadFailureKind.verification;
      case ReliableDownloadFailure.cancelled:
        return DownloadFailureKind.unknown;
      case ReliableDownloadFailure.network:
      case ReliableDownloadFailure.timeout:
      case ReliableDownloadFailure.httpStatus:
      case ReliableDownloadFailure.redirect:
      case ReliableDownloadFailure.conflict:
      case ReliableDownloadFailure.unknown:
        break;
    }
    final cause = error.cause;
    if (cause != null) {
      final fromCause = classifyDownloadFailure(cause);
      if (fromCause != DownloadFailureKind.unknown) return fromCause;
    }
    switch (error.kind) {
      case ReliableDownloadFailure.network:
      case ReliableDownloadFailure.timeout:
      case ReliableDownloadFailure.httpStatus:
        return DownloadFailureKind.network;
      default:
        return DownloadFailureKind.unknown;
    }
  }

  // 网络层异常（dio）：连接失败 / 超时 / 服务器错误等。
  if (error is DioException) {
    return DownloadFailureKind.network;
  }

  // 存储空间不足：iOS/Android 原生均为 errno 28；保险起见也匹配文案。
  if (error is FileSystemException) {
    final osError = error.osError;
    if (osError?.errorCode == 28 ||
        osError?.message.contains('No space left') == true) {
      return DownloadFailureKind.insufficientStorage;
    }
  }

  final text = error.toString();
  if (text.contains('No space left') || text.contains('errno = 28')) {
    return DownloadFailureKind.insufficientStorage;
  }
  // 整包 SHA 不匹配 / 解包后关键文件缺失（各 manager 以 StateError 抛出的文案）。
  if (text.contains('SHA-256') ||
      text.contains('SHA mismatch') ||
      text.contains('key files missing') ||
      text.contains('files missing')) {
    return DownloadFailureKind.verification;
  }
  return DownloadFailureKind.unknown;
}
