import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../services/app_logger.dart';
import 'audio_import_cancel.dart';

/// Android 本地音频选择器（SAF 通道）。
///
/// 不走 file_picker 的 Android 实现，有两个原因：
///
/// 1. 它取文件名时用 `getColumnIndexOrThrow(DISPLAY_NAME)`，且兜底逻辑写在同一个 try
///    里，遇到不返回该列的第三方 DocumentsProvider 会回传 `null`，撞上 non-null 的
///    [PlatformFile.name] 直接抛类型异常——异常发生在插件内部，调用方接不住。
/// 2. 它在**选择阶段**就把每个 content URI 抄进 cache，只为造出一个 [PlatformFile.path]。
///    选择器为了不误灰 m4a/flac 没做系统端 MIME 过滤，用户很容易连带选中几百 MB 的无关
///    文件，抄完才轮到白名单去丢弃它们，列表因此迟迟出不来。
///
/// 这里回传的 [PlatformFile] 只带 [PlatformFile.identifier]（content URI），
/// [PlatformFile.path] 恒为 null——Android 上没有可直接打开的文件路径，这也正是
/// file_picker 对该字段的语义定义。字节按需取：小文件（字幕）用 [readBytes]，
/// 音频用 [copyToFile] 在导入时一次性流进暂存区。
///
/// 文件名**不推断、不改写扩展名**；是否受支持由调用方按 `classifyImportFiles` 判断。
/// provider 不给 DISPLAY_NAME 时，原生会从 `_data`、文档 ID 等列里找回带后缀的真实
/// 名字（见 `PickedFileNaming`），不靠 MIME 猜——猜出来的扩展名会让白名单形同虚设。
class AndroidLocalAudioFilePicker {
  AndroidLocalAudioFilePicker({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'top.loop-back/local_audio_picker';
  final MethodChannel _channel;

  /// 唤起系统多选；用户取消或未选中任何文件时返回 null。
  Future<FilePickerResult?> pickFiles() async {
    final response = await _channel.invokeListMethod<Object?>('pickAudioFiles');
    if (response == null || response.isEmpty) return null;
    return FilePickerResult([
      for (final entry in response) _platformFileFrom(entry),
    ]);
  }

  /// 选取目录并仅列出直接子项；子目录不递归读取。
  Future<PickedAudioDirectory?> pickDirectory() async {
    return _directoryFrom(
      await _channel.invokeMethod<Object?>('pickDirectory'),
    );
  }

  /// 重新列出已持久授权的目录（「上次导入的文件夹」复用）。
  ///
  /// 授权被撤销或目录不存在时原生回 `directory_unavailable`，这里向上抛出异常，
  /// 由调用方清掉记忆并退回系统选择器。
  Future<PickedAudioDirectory> listDirectory(String uri) async {
    final directory = _directoryFrom(
      await _channel.invokeMethod<Object?>('listDirectory', {'uri': uri}),
    );
    if (directory == null) {
      throw const LocalAudioFilePickerException(
        'Directory listing returned no data',
      );
    }
    return directory;
  }

  /// 解析原生目录快照；`uri` 缺失时仍可用，只是无法记住这个文件夹。
  PickedAudioDirectory? _directoryFrom(Object? result) {
    if (result == null) return null;
    if (result is! Map<Object?, Object?>) {
      throw const LocalAudioFilePickerException('Invalid directory metadata');
    }
    final name = result['name'];
    final children = result['children'];
    if (name is! String || name.trim().isEmpty || children is! List<Object?>) {
      throw const LocalAudioFilePickerException('Invalid directory metadata');
    }
    final rawUri = result['uri'];
    final uri = rawUri is String && rawUri.isNotEmpty ? rawUri : null;
    final files = <PlatformFile>[];
    var ignoredDirectories = 0;
    for (final child in children) {
      if (child case {'isDirectory': final bool directory}) {
        if (directory) {
          ignoredDirectories++;
        } else {
          files.add(_platformFileFrom(child));
        }
      } else {
        throw const LocalAudioFilePickerException('Invalid directory entry');
      }
    }
    return PickedAudioDirectory(
      uri: uri,
      name: name,
      files: files,
      ignoredDirectories: ignoredDirectories,
    );
  }

  /// 读取 [uri] 的全部字节。仅用于字幕这类小文件，原生侧对体积设了上限。
  Future<Uint8List> readBytes(String uri) async {
    final bytes = await _channel.invokeMethod<Uint8List>('readBytes', {
      'uri': uri,
    });
    if (bytes == null) {
      throw const LocalAudioFilePickerException(
        'Android file read returned no data',
      );
    }
    return bytes;
  }

  /// 把 [uri] 的内容流式写入 [targetPath]；写失败时原生侧会清掉半成品。
  Future<void> copyToFile(
    String uri,
    String targetPath, {
    required CancelToken cancelToken,
  }) async {
    cancelToken.throwIfCanceled();
    final operationId = const Uuid().v4();
    AppLogger.log('LocalAudioPicker', 'copy_begin operation=$operationId');
    final cancelCopy = cancelToken.whenCancel.then((_) async {
      AppLogger.log(
        'LocalAudioPicker',
        'cancel_dispatch operation=$operationId',
      );
      try {
        await _channel.invokeMethod<void>('cancelCopyToFile', {
          'operationId': operationId,
        });
        AppLogger.log('LocalAudioPicker', 'cancel_ack operation=$operationId');
      } catch (error) {
        AppLogger.log(
          'LocalAudioPicker',
          'cancel_dispatch_failed operation=$operationId '
              'error=${error.runtimeType}',
        );
        rethrow;
      }
    });
    try {
      await _channel.invokeMethod<void>('copyToFile', {
        'uri': uri,
        'targetPath': targetPath,
        'operationId': operationId,
      });
      cancelToken.throwIfCanceled();
      AppLogger.log('LocalAudioPicker', 'copy_complete operation=$operationId');
    } on PlatformException catch (error) {
      AppLogger.log(
        'LocalAudioPicker',
        'copy_platform_error operation=$operationId code=${error.code} '
            'canceled=${cancelToken.isCancelled}',
      );
      if (cancelToken.isCancelled) cancelToken.throwIfCanceled();
      rethrow;
    } catch (error) {
      AppLogger.log(
        'LocalAudioPicker',
        'copy_failed operation=$operationId canceled=${cancelToken.isCancelled} '
            'error=${error.runtimeType}',
      );
      rethrow;
    } finally {
      cancelCopy.catchError((_) {});
      AppLogger.log(
        'LocalAudioPicker',
        'copy_settled operation=$operationId canceled=${cancelToken.isCancelled}',
      );
    }
  }

  /// 校验原生协议后构造 [PlatformFile]，避免平台侧回归重新引入空类型异常。
  PlatformFile _platformFileFrom(Object? entry) {
    if (entry is! Map<Object?, Object?>) {
      throw const LocalAudioFilePickerException('Invalid Android file record');
    }
    final uri = entry['uri'];
    final name = entry['name'];
    final size = entry['size'];
    if (uri is! String || uri.isEmpty || name is! String || name.isEmpty) {
      throw const LocalAudioFilePickerException(
        'Android file metadata is missing',
      );
    }
    if (size is! int || size < 0) {
      throw const LocalAudioFilePickerException('Android file size is invalid');
    }
    return PlatformFile(identifier: uri, name: name, size: size);
  }
}

/// SAF 返回的目录快照，只含直接文件与被忽略子目录的数量。
class PickedAudioDirectory {
  const PickedAudioDirectory({
    required this.name,
    required this.files,
    this.uri,
    this.ignoredDirectories = 0,
    this.unsupportedCount = 0,
  });
  final String name;
  final List<PlatformFile> files;

  /// SAF tree URI（已持久授权）；为空表示这个目录无法记住，下次需重新选择。
  final String? uri;
  final int ignoredDirectories;
  final int unsupportedCount;
}

class LocalAudioFilePickerException implements Exception {
  const LocalAudioFilePickerException(this.message);

  final String message;

  @override
  String toString() => message;
}
