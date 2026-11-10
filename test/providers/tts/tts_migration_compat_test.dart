/// TTS 迁移兼容回归（issue #24）
///
/// 覆盖「升级迁移」契约（docs/features/20261110-tts-provider-decoupling/plan.md
/// 迁移规则表）：已装旧 install.json（resourceId 不变）继续识别且不重下；引擎/音色/
/// 变体/口音偏好保留；已移除音色 lessac/alan 的孤儿目录被清理、存量偏好回退默认；
/// 合成缓存键按 voiceId/modelTag 分桶、品牌改名不失效；损坏安装回到未安装态；
/// 新装默认（含英音 cori）不变。与 #23（设置页/ARB/widget）并行，本文件不触碰
/// 设置页与 ARB/widget 测试文件。
library;

import 'dart:convert';
import 'dart:io';

import 'package:echo_loop/providers/tts/kokoro_model_provider.dart';
import 'package:echo_loop/providers/tts/tts_settings_provider.dart';
import 'package:echo_loop/services/storage_migration_service.dart';
import 'package:echo_loop/services/tts/kokoro_model_catalog.dart';
import 'package:echo_loop/services/tts/kokoro_model_manager.dart';
import 'package:echo_loop/services/tts/kokoro_voices.dart';
import 'package:echo_loop/services/tts/piper_model_catalog.dart';
import 'package:echo_loop/services/tts/tts_cache_store.dart';
import 'package:echo_loop/services/tts/tts_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 写入一份 Kokoro fp32 的有效安装：旧 install.json（resourceId 不变）+ 关键文件。
///
/// [missingModelFile] 为真时省略 `model.onnx`，模拟「截断/损坏安装」。
Future<void> _writeKokoroInstall(
  Directory root, {
  bool missingModelFile = false,
}) async {
  final dir = Directory(p.join(root.path, 'kokoro-en-v0_19'))
    ..createSync(recursive: true);
  if (!missingModelFile) {
    await File(p.join(dir.path, 'model.onnx')).writeAsBytes([1, 2, 3]);
  }
  await File(p.join(dir.path, 'voices.bin')).writeAsBytes([4]);
  await File(p.join(dir.path, 'tokens.txt')).writeAsBytes([5]);
  final dataDir = Directory(p.join(dir.path, 'espeak-ng-data'))
    ..createSync(recursive: true);
  await File(p.join(dataDir.path, 'phondata')).writeAsBytes([6]);
  await File(p.join(dir.path, 'install.json')).writeAsString(
    jsonEncode({
      'resourceId': 'kokoro-en-v0_19',
      'installAt': '2026-01-01T00:00:00.000Z',
      'resourceSize': 10,
    }),
  );
}

/// 写入一份 Piper 音色的有效安装（旧 install.json + onnx/tokens/espeak）。
Future<void> _writePiperInstall(Directory root, String voiceId) async {
  final dir = Directory(p.join(root.path, voiceId))
    ..createSync(recursive: true);
  await File(p.join(dir.path, '$voiceId.onnx')).writeAsBytes([1, 2, 3]);
  await File(p.join(dir.path, 'tokens.txt')).writeAsBytes([4]);
  final dataDir = Directory(p.join(dir.path, 'espeak-ng-data'))
    ..createSync(recursive: true);
  await File(p.join(dataDir.path, 'phondata')).writeAsBytes([5]);
  await File(p.join(dir.path, 'install.json')).writeAsString(
    jsonEncode({
      'resourceId': voiceId,
      'installAt': '2026-01-01T00:00:00.000Z',
      'resourceSize': 10,
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('已装旧 install.json 迁移', () {
    test('Kokoro 旧安装（resourceId 不变）→ 识别为已下载且不重下', () async {
      final root = await Directory.systemTemp.createTemp('tts_migrate_kokoro_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      await _writeKokoroInstall(root);

      final managers = <KokoroModelVariant, KokoroModelManager>{};
      final container = ProviderContainer(
        overrides: [
          kokoroModelManagerProvider.overrideWith((ref, variant) {
            return managers.putIfAbsent(
              variant,
              () => KokoroModelManager(
                spec: kokoroSpecOf(variant),
                modelsRootResolver: () async => root.path,
              ),
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(() {
        for (final manager in managers.values) {
          manager.dispose();
        }
      });

      await container
          .read(kokoroModelProvider.notifier)
          .refreshInstalledStates();

      final state = container
          .read(kokoroModelProvider)
          .of(KokoroModelVariant.fp32);
      expect(state.isReady, isTrue);
      // 目录内容未被替换/重下：模型文件仍原样存在。
      expect(
        File(p.join(root.path, 'kokoro-en-v0_19', 'model.onnx')).existsSync(),
        isTrue,
      );
      // 未安装的 int8 变体保持未下载，未被迁移误判为就绪。
      expect(
        container.read(kokoroModelProvider).of(KokoroModelVariant.int8).isReady,
        isFalse,
      );
    });

    test('已移除音色（lessac/alan）孤儿目录 → 启动迁移清理', () async {
      final root = await Directory.systemTemp.createTemp('tts_orphan_cleanup_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      await _writePiperInstall(root, 'en_US-lessac-medium');
      await _writePiperInstall(root, 'en_GB-alan-medium');
      await _writePiperInstall(root, 'en_US-amy-medium'); // 仍保留

      await removeOrphanPiperModelDirs(
        removedPiperVoiceIds,
        modelsRootResolver: () async => root.path,
      );

      expect(
        Directory(p.join(root.path, 'en_US-lessac-medium')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(root.path, 'en_GB-alan-medium')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(root.path, 'en_US-amy-medium')).existsSync(),
        isTrue,
      );
    });

    test('损坏安装（关键文件缺失）→ 回到未安装态', () async {
      final root = await Directory.systemTemp.createTemp('tts_migrate_bad_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      await _writeKokoroInstall(root, missingModelFile: true);

      final managers = <KokoroModelVariant, KokoroModelManager>{};
      final container = ProviderContainer(
        overrides: [
          kokoroModelManagerProvider.overrideWith((ref, variant) {
            return managers.putIfAbsent(
              variant,
              () => KokoroModelManager(
                spec: kokoroSpecOf(variant),
                modelsRootResolver: () async => root.path,
              ),
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(() {
        for (final manager in managers.values) {
          manager.dispose();
        }
      });

      await container
          .read(kokoroModelProvider.notifier)
          .refreshInstalledStates();

      final state = container
          .read(kokoroModelProvider)
          .of(KokoroModelVariant.fp32);
      expect(state.isReady, isFalse);
      expect(state.installManifest, isNull);
    });
  });

  group('偏好保留与新装默认', () {
    test('存量偏好保留，lessac/alan 回退对应口音默认', () async {
      SharedPreferences.setMockInitialValues({
        TtsSettingsKeys.engine: TtsEngineKind.piper.name,
        TtsSettingsKeys.accent: TtsAccent.uk.name,
        TtsSettingsKeys.kokoroVoiceUs: 'am_michael',
        TtsSettingsKeys.kokoroVoiceUk: 'bm_lewis',
        TtsSettingsKeys.kokoroVariant: KokoroModelVariant.int8.name,
        TtsSettingsKeys.piperVoiceUs: 'en_US-lessac-medium',
        TtsSettingsKeys.piperVoiceUk: 'en_GB-alan-medium',
      });
      final prefs = await SharedPreferences.getInstance();

      await fallbackRemovedPiperVoicePreferences(prefs);

      // 其它偏好保留，已移除音色写回对应口音默认。
      expect(prefs.getString(TtsSettingsKeys.engine), TtsEngineKind.piper.name);
      expect(prefs.getString(TtsSettingsKeys.accent), TtsAccent.uk.name);
      expect(prefs.getString(TtsSettingsKeys.kokoroVoiceUs), 'am_michael');
      expect(prefs.getString(TtsSettingsKeys.kokoroVoiceUk), 'bm_lewis');
      expect(prefs.getString(TtsSettingsKeys.piperVoiceUs), 'en_US-amy-medium');
      expect(prefs.getString(TtsSettingsKeys.piperVoiceUk), 'en_GB-cori-medium');
      final s = TtsSettings.fromPrefsSync(prefs);
      expect(s.activePiperVoice, 'en_GB-cori-medium');
    });

    test('新装默认不变（含英音默认已改 cori）', () {
      const s = TtsSettings();
      expect(s.engine, TtsEngineKind.kokoro);
      expect(s.kokoroVariant, KokoroModelVariant.fp32);
      expect(s.kokoroVoiceUs, 'af_sarah');
      expect(s.kokoroVoiceUk, 'bf_emma');
      expect(s.piperVoiceUs, 'en_US-amy-medium');
      expect(s.piperVoiceUk, 'en_GB-cori-medium');
      // 目录常量与设置默认保持一致，避免两处漂移。
      expect(kokoroDefaultVoiceUs, 'af_sarah');
      expect(kokoroDefaultVoiceUk, 'bf_emma');
      expect(piperDefaultVoiceUs, 'en_US-amy-medium');
      expect(piperDefaultVoiceUk, 'en_GB-cori-medium');
    });

    test('其它无效值不写回默认（只处理被移除的两个 ID）', () async {
      SharedPreferences.setMockInitialValues({
        TtsSettingsKeys.piperVoiceUs: 'bogus',
        TtsSettingsKeys.piperVoiceUk: 'en_GB-alan-medium',
      });
      final prefs = await SharedPreferences.getInstance();

      await fallbackRemovedPiperVoicePreferences(prefs);

      expect(prefs.getString(TtsSettingsKeys.piperVoiceUs), 'bogus');
      expect(prefs.getString(TtsSettingsKeys.piperVoiceUk), 'en_GB-cori-medium');
      expect(piperDefaultVoiceUk, 'en_GB-cori-medium');
    });
  });

  group('合成缓存键身份', () {
    test('缓存键含 voiceId/modelTag 分桶，且不因品牌改名失效', () {
      final store = TtsCacheStore(
        // deriveKey 是纯函数，不触达 DAO/目录；抛错闭包防未预期调用。
        resolveDao: () => throw StateError('deriveKey 不应触达 DAO'),
        resolveCacheDir: () async => throw StateError('deriveKey 不应触达缓存目录'),
      );

      String derive(String voiceId, String modelTag) => store.deriveKey(
        text: 'Hello',
        engine: TtsEngineKind.kokoro,
        voiceId: voiceId,
        speed: 0.45,
        modelTag: modelTag,
      );

      final base = derive('af_sarah', 'fp32');
      // 模型文件身份不变（同 voiceId/modelTag）→ 键稳定，缓存持续有效。
      expect(derive('af_sarah', 'fp32'), base);
      // 变体分桶：modelTag 不同 → 键不同。
      expect(derive('af_sarah', 'int8'), isNot(base));
      // 音色分桶：voiceId 不同 → 键不同。
      expect(derive('bf_emma', 'fp32'), isNot(base));
      // 品牌改名不参与缓存键：纯摘要，无任何可读品牌串。
      expect(base.contains('echo'), isFalse);
      expect(base.contains('Echo'), isFalse);
    });
  });
}
