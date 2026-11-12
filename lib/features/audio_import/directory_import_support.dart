/// 目录导入的平台可用性。
///
/// 目录选择只有 Android 有 SAF 通道实现（`AndroidLocalAudioPicker` 原生侧 +
/// `AndroidLocalAudioFilePicker` Dart 侧）；其他平台调用会落到
/// `MissingPluginException`，因此入口本身按平台收起。
/// 抽成 provider 是为了让 widget 测试能在非 Android 宿主上验证完整流程。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

final directoryImportSupportedProvider = Provider<bool>(
  (ref) => !kIsWeb && Platform.isAndroid,
);
