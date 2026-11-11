import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 桌面窗口全屏桥接。
///
/// macOS 窗口全屏桥接。
///
/// 原生端只在系统实际完成进入或退出全屏后发送状态，避免页面先进入伪全屏。
abstract class WindowFullscreenController {
  Stream<bool> get changes;
  Future<bool> setFullscreen(bool fullscreen);
  Future<void> dispose();
}

class WindowFullscreenService implements WindowFullscreenController {
  WindowFullscreenService({MethodChannel channel = _defaultChannel})
    : _channel = channel {
    _channel.setMethodCallHandler(_handlePlatformCall);
  }

  static const _defaultChannel = MethodChannel('top.loop-back/window');

  final MethodChannel _channel;
  final _changes = StreamController<bool>.broadcast(sync: true);

  @override
  Stream<bool> get changes => _changes.stream;

  @override
  Future<bool> setFullscreen(bool fullscreen) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('setFullscreen', {
        'fullscreen': fullscreen,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<dynamic> _handlePlatformCall(MethodCall call) async {
    if (call.method != 'fullscreenChanged') return null;
    final fullscreen = call.arguments;
    if (fullscreen is bool && !_changes.isClosed) {
      _changes.add(fullscreen);
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    await _changes.close();
  }
}
