/// TTS 引擎共享的 espeak-ng-data 修复安装。
///
/// `espeak-ng-data` 是 Kokoro 与 Piper 共用的发音数据依赖（D12）。模型本体齐全、
/// 仅该目录缺失或损坏（以核心文件 `phondata` 为完整性标记）时，只下载独立归档
/// 解包进模型目录，不重下模型本体。两个模型管理器复用这里的同一实现，避免
/// 两处逻辑漂移。
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../app_logger.dart';
import '../asr/asr_model_catalog.dart'
    show AsrDownloadSource, AsrPublicResourceSpec, AsrResourceFile;
import '../resource_archive_installer.dart';
import 'tts_shared_resource_catalog.dart' show ttsEspeakNgDataResourceId;

/// espeak-ng-data 目录是否需要修复：目录缺失，或完整性标记 `phondata` 缺失。
///
/// [dataDirPath] 为已定位到的 `espeak-ng-data` 目录绝对路径；null 表示目录缺失。
bool ttsEspeakDataNeedsRepair(String? dataDirPath) {
  if (dataDirPath == null) return true;
  return !File(p.join(dataDirPath, 'phondata')).existsSync();
}

/// 只下载共享 `espeak-ng-data` 归档并解包进模型目录（不重下模型本体）。
///
/// [existingDataDirPath] 为模型目录内已定位到的 `espeak-ng-data` 目录绝对路径
/// （可能为 null）；[uriFor] 与 [installer] 由调用方注入，保持网络与安装管线可控。
Future<void> installTtsEspeakData({
  required String logTag,
  required Directory root,
  required Directory target,
  required String dataDirectoryName,
  required String? existingDataDirPath,
  required Map<String, AsrPublicResourceSpec> resourceRegistry,
  required ResourceArchiveInstaller installer,
  required AsrDownloadSource source,
  required Uri Function(
    AsrPublicResourceSpec resource,
    AsrResourceFile file,
    AsrDownloadSource source,
  )
  uriFor,
  CancelToken? cancelToken,
}) async {
  final resource = resourceRegistry[ttsEspeakNgDataResourceId];
  if (resource == null) {
    throw StateError('$logTag missing espeak resource: $ttsEspeakNgDataResourceId');
  }
  final file = resource.files.single;
  final dataDir = existingDataDirPath != null
      ? Directory(existingDataDirPath)
      : Directory(p.join(target.path, dataDirectoryName));
  AppLogger.log(
    logTag,
    '补 espeak-ng-data into=${dataDir.path} url=${uriFor(resource, file, source)}',
  );
  await installer.install(
    root: root,
    target: dataDir,
    resourceId: resource.id,
    archiveFileName: '_download_${resource.id}.tar.gz',
    uri: uriFor(resource, file, source),
    expectedSha256: file.sha256,
    cancelToken: cancelToken,
    extractAndValidate: (archive, staging) async {
      await extractFileToDisk(archive.path, staging.path);
      // espeak-ng-data 归档根级平铺，以核心数据文件作为完整性标记。
      if (!File(p.join(staging.path, 'phondata')).existsSync()) {
        throw StateError(
          'espeak-ng-data key files missing after extraction in '
          '${staging.path}',
        );
      }
    },
  );
}
