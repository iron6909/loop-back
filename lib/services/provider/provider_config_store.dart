/// 配置进入普通偏好，API Key 仅进入平台安全存储。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'provider_config.dart';

class ProviderConfigStore {
  ProviderConfigStore({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
    Future<SharedPreferences> Function()? preferences,
  }) : _secure = secureStorage,
       _preferences = preferences ?? SharedPreferences.getInstance;

  final FlutterSecureStorage _secure;
  final Future<SharedPreferences> Function() _preferences;
  static const _configKey = 'ai_provider_config_v1';
  static const _secretKey = 'ai_provider_key_v1';
  Future<void> _pending = Future.value();

  Future<ProviderConfig?> read() async {
    await _pending;
    return _readConfig(await _preferences());
  }

  ProviderConfig? _readConfig(SharedPreferences prefs) {
    final raw = prefs.getString(_configKey);
    if (raw == null) return null;
    try {
      return ProviderConfig.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  Future<String?> readApiKey() async {
    await _pending;
    final value = await _secure.read(key: _secretKey);
    return value == null || value.trim().isEmpty ? null : value;
  }

  Future<bool> isConfigured() async =>
      await read() != null && await readApiKey() != null;

  /// 串行写入，切换地址先清旧 Key，失败时不会把旧凭据发送至新地址。
  Future<void> save(ProviderConfig config, {String? apiKey}) =>
      _enqueue(() async {
        if (baseUrlError(config.baseUrl) != null ||
            config.model.trim().isEmpty ||
            config.promptVersion.trim().isEmpty) {
          throw ArgumentError('供应商配置无效');
        }
        if (apiKey != null && RegExp(r'[\r\n]').hasMatch(apiKey)) {
          throw ArgumentError('API Key 不能包含换行');
        }
        final prefs = await _preferences();
        final old = _readConfig(prefs);
        if (old?.baseUrl != config.baseUrl || old?.kind != config.kind) {
          await _secure.delete(key: _secretKey);
        }
        // 先落配置，安全存储失败时保持未配置状态，避免错用其他供应商的 Key。
        if (!await prefs.setString(_configKey, jsonEncode(config.toJson()))) {
          throw StateError('无法保存供应商配置');
        }
        if (apiKey != null) {
          if (apiKey.trim().isEmpty) {
            await _secure.delete(key: _secretKey);
          } else {
            await _secure.write(key: _secretKey, value: apiKey.trim());
          }
        }
      });

  Future<void> clearKey() => _enqueue(() => _secure.delete(key: _secretKey));

  /// 队列始终可继续，单次失败仍交给对应调用方处理。
  Future<void> _enqueue(Future<void> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
