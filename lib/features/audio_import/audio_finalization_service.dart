import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:universal_io/io.dart';
import 'package:uuid/uuid.dart';

import '../../services/app_logger.dart';
import '../../utils/audio_fingerprint.dart';
import 'audio_import_cancel.dart';
import 'audio_import_file_copy.dart';
import 'audio_import_models.dart';
import 'audio_transcode_service.dart';
import '../../../utils/file_cleanup.dart';

/// 音频落盘结果。
///
/// [relativePath] 正式音频相对数据目录的路径；[sha256] 为内容指纹，用作稳定
/// 文件名；[originalSha256] 为转码前原始音频指纹（供 AI 转录缓存复用，导入时
/// 与 [sha256] 相等）；[created] 表示是否新写入文件（false 表示命中同指纹已有
/// 文件、直接复用）。
class FinalizedAudio {
  const FinalizedAudio({
    required this.relativePath,
    required this.sha256,
    required this.originalSha256,
    required this.created,
  });

  final String relativePath;
  final String sha256;
  final String originalSha256;
  final bool created;
}

/// 临时音频按内容指纹落盘 + 转录后转码的共享流程。
///
/// 链接下载（[AudioImportService]）和本地导入（添加音频对话框）都走 [finalize]，
/// 保证指纹复用、临时文件清理两处一致。导入阶段**不转码**，直接保留原始音频
/// （导入更快、AI 转录上传原始更高质量）；转码延后到 AI 转录成功后，由
/// [transcodeExisting] 把原始文件转码为 m4a。
class AudioFinalizationService {
  AudioFinalizationService({
    AudioTranscodeService? transcodeService,
    Future<String> Function(String absolutePath)? computeSha256,
    Future<String> Function(String absolutePath, {CancelToken? cancelToken})?
    computeSha256WithCancellation,
    Uuid? uuid,
  }) : _transcodeService = transcodeService ?? AudioTranscodeService(),
       _computeSha256 =
           computeSha256WithCancellation ??
           (computeSha256 == null
               ? computeAudioSha256
               : (path, {CancelToken? cancelToken}) => computeSha256(path)),
       _uuid = uuid ?? const Uuid();

  final AudioTranscodeService _transcodeService;
  final Future<String> Function(String absolutePath, {CancelToken? cancelToken})
  _computeSha256;
  final Uuid _uuid;

  /// 按内容指纹把 [tempRelativePath] 指向的临时音频落盘到 [targetSubdir]。
  ///
  /// [dataDir] 应用数据根目录；[tempRelativePath] / [targetSubdir] 均相对它，
  /// 例如 `tmp/audio_import/xxx.mp3` 与 `audios/imported`。**不转码**，保留原始
  /// 格式与扩展名。同指纹文件已存在时复用现有文件、删除本次临时产物；无论命中
  /// 与否都会清理原始临时文件。
  Future<FinalizedAudio> finalize({
    required Directory dataDir,
    required String tempRelativePath,
    required String targetSubdir,
    CancelToken? cancelToken,
  }) async {
    final traceId = cancelToken?.hashCode.toRadixString(16) ?? 'none';
    final stopwatch = Stopwatch()..start();
    final targetDir = Directory(p.join(dataDir.path, targetSubdir));
    final sourceFile = File(p.join(dataDir.path, tempRelativePath));
    AppLogger.log('AudioImportFinalize', 'begin trace=$traceId');
    try {
      cancelToken?.throwIfCanceled();
      await targetDir.create(recursive: true);

      AppLogger.log('AudioImportFinalize', 'fingerprint_begin trace=$traceId');
      final sha256 = await _fingerprint(sourceFile, cancelToken);
      AppLogger.log(
        'AudioImportFinalize',
        'fingerprint_complete trace=$traceId '
            'elapsed_ms=${stopwatch.elapsedMilliseconds}',
      );
      cancelToken?.throwIfCanceled();
      final finalName = '$sha256${p.extension(sourceFile.path)}';
      final finalFile = File(p.join(targetDir.path, finalName));

      final created = !await finalFile.exists();
      if (created) {
        cancelToken?.throwIfCanceled();
        await _moveToFinal(
          sourceFile: sourceFile,
          finalFile: finalFile,
          cancelToken: cancelToken,
        );
      } else {
        await deleteFileQuietly(sourceFile);
      }

      AppLogger.log(
        'AudioImportFinalize',
        'complete trace=$traceId created=$created '
            'elapsed_ms=${stopwatch.elapsedMilliseconds}',
      );
      return FinalizedAudio(
        relativePath: p.join(targetSubdir, finalName),
        sha256: sha256,
        originalSha256: sha256,
        created: created,
      );
    } catch (error) {
      AppLogger.log(
        'AudioImportFinalize',
        'failed trace=$traceId canceled=${cancelToken?.isCancelled ?? false} '
            'error=${error.runtimeType} elapsed_ms=${stopwatch.elapsedMilliseconds}',
      );
      await deleteFileQuietly(sourceFile);
      rethrow;
    }
  }

  /// 把已落盘的原始音频 [relativePath] 转码为 m4a，按转码后指纹落盘到同目录。
  ///
  /// 转录成功后调用。**不删除原始文件**（由调用方在 DB 更新后删除，避免中途崩溃
  /// 导致 audioPath 指向不存在文件）。转码失败抛 [AudioImportException]，由调用方
  /// catch 后静默处理（保留原始、不阻塞转录成功）。同指纹 m4a 已存在时复用。
  Future<FinalizedAudio> transcodeExisting({
    required Directory dataDir,
    required String relativePath,
  }) async {
    final source = File(p.join(dataDir.path, relativePath));
    final targetSubdir = p.dirname(relativePath);
    final tmpDir = Directory(p.join(dataDir.path, 'tmp', 'audio_import'));
    await tmpDir.create(recursive: true);
    final tmpOutput = File(p.join(tmpDir.path, '${_uuid.v4()}.m4a'));

    try {
      final ok = await _transcodeService.transcodeToFile(
        source: source,
        output: tmpOutput,
      );
      if (!ok) {
        throw const AudioImportException(
          AudioImportFailureCode.storage,
          'Failed to transcode audio',
        );
      }

      final sha256 = await _fingerprint(tmpOutput);
      final finalName = '$sha256.m4a';
      final finalFile = File(p.join(dataDir.path, targetSubdir, finalName));

      final created = !await finalFile.exists();
      if (created) {
        await _moveToFinal(sourceFile: tmpOutput, finalFile: finalFile);
      }

      return FinalizedAudio(
        relativePath: p.join(targetSubdir, finalName),
        sha256: sha256,
        originalSha256: sha256,
        created: created,
      );
    } finally {
      // 兜底清理临时产物：成功 move 后 tmpOutput 已不存在；命中已有文件、
      // fingerprint/move 抛异常等情形在此删除残留（Android 无 /tmp 自动清理）。
      await deleteFileQuietly(tmpOutput);
    }
  }

  /// 计算指纹，失败统一抛存储类异常，便于上层归一处理。
  Future<String> _fingerprint(File file, [CancelToken? cancelToken]) async {
    try {
      return await _computeSha256(file.path, cancelToken: cancelToken);
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      throw AudioImportException(
        AudioImportFailureCode.storage,
        'Failed to fingerprint audio',
        e,
      );
    }
  }

  /// 移动到正式目录；跨卷 rename 失败时回退 copy，并清理半成品。
  Future<void> _moveToFinal({
    required File sourceFile,
    required File finalFile,
    CancelToken? cancelToken,
  }) async {
    try {
      await sourceFile.rename(finalFile.path);
      return;
    } on FileSystemException {
      try {
        await copyAudioImportStreamToFile(
          source: sourceFile.openRead(),
          destination: finalFile,
          cancelToken: cancelToken,
        );
        await deleteFileQuietly(sourceFile);
        return;
      } catch (e) {
        await deleteFileQuietly(finalFile);
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
        if (e is! FileSystemException) rethrow;
        throw AudioImportException(
          AudioImportFailureCode.storage,
          'Failed to save audio',
          e,
        );
      }
    }
  }
}
