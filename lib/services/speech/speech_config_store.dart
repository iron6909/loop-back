/// 在线语音配置的持久化：普通配置与在线模型进偏好，Key 只进平台安全存储。
///
/// 与文字 AI 的 `ProviderConfigStore` 使用不同的存储槽，两边的 Key 互不引用；
/// 串行保存、地址或服务类型变化清旧 Key、非法地址拒绝等规则一致。
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../provider/provider_config.dart' show baseUrlError;
import 'speech_config.dart';

class SpeechConfigStore {
  SpeechConfigStore({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
    Future<SharedPreferences> Function()? preferences,
  }) : _secure = secureStorage,
       _preferences = preferences ?? SharedPreferences.getInstance;

  final FlutterSecureStorage _secure;
  final Future<SharedPreferences> Function() _preferences;

  /// 普通配置槽：可进入备份。
  static const configPreferenceKey = 'speech_provider_config_v1';

  /// 非秘密的凭据版本：Key 变化时换成新令牌，使绑定旧凭据的能力验证失效。
  ///
  /// 用随机令牌而不是计数或 Key 摘要，既不暴露 Key 材料，也不会因两台设备
  /// 的计数巧合而让恢复后的旧验证重新生效。
  static const credentialVersionPreferenceKey =
      'speech_provider_credential_version_v1';

  /// 安全 Key 槽：只在平台安全存储，不进入偏好、备份、日志或埋点。
  static const _secretKey = 'speech_provider_key_v1';

  Future<void> _pending = Future.value();

  Future<SpeechConfig?> read() async {
    await _pending;
    return _readConfig(await _preferences());
  }

  SpeechConfig? _readConfig(SharedPreferences preferences) {
    final raw = preferences.getString(configPreferenceKey);
    if (raw == null) return null;
    try {
      return SpeechConfig.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  Future<String?> readApiKey() async {
    await _pending;
    return _readSecret();
  }

  /// 当前凭据版本；null 表示从未保存过凭据。
  Future<String?> readCredentialVersion() async {
    await _pending;
    final preferences = await _preferences();
    return preferences.getString(credentialVersionPreferenceKey);
  }

  Future<bool> isConfigured() async =>
      await read() != null && await readApiKey() != null;

  /// 串行写入。地址或服务类型变化先清旧 Key，避免把旧凭据发到新地址；
  /// 只改模型时保留 Key 与凭据版本。
  Future<void> save(SpeechConfig config, {String? apiKey}) =>
      _enqueue(() async {
        if (baseUrlError(config.baseUrl) != null) {
          throw ArgumentError('在线语音服务地址无效');
        }
        if (apiKey != null && RegExp(r'[\r\n]').hasMatch(apiKey)) {
          throw ArgumentError('API Key 不能包含换行');
        }
        final preferences = await _preferences();
        final old = _readConfig(preferences);
        var currentKey = await _readSecret();
        if (old?.baseUrl != config.baseUrl || old?.kind != config.kind) {
          if (currentKey != null) {
            await _secure.delete(key: _secretKey);
            await _bumpCredentialVersion(preferences);
            currentKey = null;
          }
        }
        // 先落配置，安全存储失败时保持未配置状态，避免错用其他服务的 Key。
        if (!await preferences.setString(
          configPreferenceKey,
          jsonEncode(config.toJson()),
        )) {
          throw StateError('无法保存在线语音配置');
        }
        if (apiKey == null) return;
        final nextKey = apiKey.trim();
        if (nextKey.isEmpty) {
          if (currentKey != null) {
            await _secure.delete(key: _secretKey);
            await _bumpCredentialVersion(preferences);
          }
          return;
        }
        if (nextKey == currentKey) return;
        await _secure.write(key: _secretKey, value: nextKey);
        await _bumpCredentialVersion(preferences);
      });

  /// 删除 Key 并让旧验证失效，保留普通配置。
  Future<void> clearKey() => _enqueue(() async {
    if (await _readSecret() == null) return;
    await _secure.delete(key: _secretKey);
    await _bumpCredentialVersion(await _preferences());
  });

  /// 显式让绑定旧凭据的能力验证失效；备份恢复成功后调用。
  Future<void> rotateCredentialVersion() => _enqueue(() async {
    await _bumpCredentialVersion(await _preferences());
  });

  Future<String?> _readSecret() async {
    final value = await _secure.read(key: _secretKey);
    return value == null || value.trim().isEmpty ? null : value;
  }

  Future<void> _bumpCredentialVersion(SharedPreferences preferences) async {
    if (!await preferences.setString(
      credentialVersionPreferenceKey,
      _newCredentialVersion(),
    )) {
      throw StateError('无法保存在线语音凭据版本');
    }
  }

  static String _newCredentialVersion() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// 队列始终可继续，单次失败仍交给对应调用方处理。
  Future<void> _enqueue(Future<void> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
