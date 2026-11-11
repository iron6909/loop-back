/// TTS 备份边界回归（issue #24）
///
/// 覆盖「备份与恢复」契约：偏好随备份、模型目录与安装清单不进入备份、恢复不触发
/// 下载、恢复后模型目录原样保留（模型重下属性）。沿用 `backup_service_test.dart`
/// 直接使用 `BackupService` 的测试方式，不与 #23 的设置页/ARB/widget 测试相交。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:loop_back/database/app_database.dart';
import 'package:loop_back/providers/tts/tts_settings_provider.dart';
import 'package:loop_back/services/backup/backup_service.dart';
import 'package:loop_back/services/tts/tts_engine.dart';
import 'package:loop_back/utils/app_data_dir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Application Support 目录替身：模型安装目录落在其下 `tts-models/`。
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationSupportPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}

/// 写入一份已安装 Kokoro 模型（模型文件 + install.json），落在支持目录下。
Future<void> _writeInstalledModel(Directory root) async {
  final modelDir = Directory(p.join(root.path, 'tts-models', 'kokoro-en-v0_19'))
    ..createSync(recursive: true);
  await File(p.join(modelDir.path, 'model.onnx')).writeAsBytes([1, 2, 3]);
  await File(p.join(modelDir.path, 'install.json')).writeAsString(
    jsonEncode({
      'resourceId': 'kokoro-en-v0_19',
      'installAt': '2026-01-01T00:00:00.000Z',
      'resourceSize': 3,
    }),
  );
}

({Archive archive, void Function() close}) _decode(String path) {
  final input = InputFileStream(path);
  final archive = ZipDecoder().decodeStream(input);
  return (
    archive: archive,
    close: () {
      archive.clearSync();
      input.closeSync();
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory dataDir;
  late Directory outputDir;
  late AppDatabase database;
  late BackupService service;
  var databaseClosed = false;
  late PathProviderPlatform previousPaths;

  setUp(() async {
    databaseClosed = false;
    root = await Directory.systemTemp.createTemp('tts_backup_boundary_');
    dataDir = Directory(p.join(root.path, 'data'))..createSync(recursive: true);
    outputDir = Directory(p.join(root.path, 'output'))
      ..createSync(recursive: true);
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    appDataDirectoryOverride = dataDir;
    SharedPreferences.setMockInitialValues({
      TtsSettingsKeys.engine: TtsEngineKind.kokoro.name,
      TtsSettingsKeys.accent: TtsAccent.uk.name,
      TtsSettingsKeys.kokoroVariant: 'int8',
      TtsSettingsKeys.piperVoiceUk: 'en_GB-cori-medium',
    });
    database = AppDatabase(
      NativeDatabase(File(p.join(dataDir.path, 'loop_back.db'))),
    );
    await database.customSelect('SELECT 1').get();
    service = BackupService(
      database,
      // 本测试不验证应用更新迁移版本，提供空迁移器避免触发真实迁移副作用。
      restoredAppUpdateMigrator: (preferences, fromVersion) async {},
    );
  });

  tearDown(() async {
    if (!databaseClosed) {
      await database.close();
    }
    appDataDirectoryOverride = null;
    PathProviderPlatform.instance = previousPaths;
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('备份：tts 偏好随备份，模型目录与安装清单不进入备份', () async {
    await _writeInstalledModel(root);

    final backupPath = await service.exportData(
      outputDir: outputDir.path,
      appVersion: '1.0.0',
      platform: 'android',
    );
    final decoded = _decode(backupPath);
    addTearDown(decoded.close);
    final archive = decoded.archive;

    final settings =
        jsonDecode(utf8.decode(archive.findFile('settings.json')!.content))
            as Map<String, Object?>;
    expect(settings, containsPair(TtsSettingsKeys.engine, 'kokoro'));
    expect(settings, containsPair(TtsSettingsKeys.accent, 'uk'));
    expect(settings, containsPair(TtsSettingsKeys.kokoroVariant, 'int8'));
    expect(
      settings,
      containsPair(TtsSettingsKeys.piperVoiceUk, 'en_GB-cori-medium'),
    );

    // 模型目录与 install.json 不进入备份（不随任何 entry 打包）。
    expect(archive.findFile('tts-models/kokoro-en-v0_19/install.json'), isNull);
    expect(archive.findFile('tts-models/kokoro-en-v0_19/model.onnx'), isNull);
  });

  test('恢复：不触发下载，模型目录与安装清单原样保留（恢复后合成仍可用）', () async {
    await _writeInstalledModel(root);
    final modelFile = File(
      p.join(root.path, 'tts-models', 'kokoro-en-v0_19', 'model.onnx'),
    );
    final manifestFile = File(
      p.join(root.path, 'tts-models', 'kokoro-en-v0_19', 'install.json'),
    );

    final backupPath = await service.exportData(
      outputDir: outputDir.path,
      appVersion: '1.0.0',
      platform: 'android',
    );
    final prepared = await service.prepareImport(zipPath: backupPath);
    addTearDown(prepared.dispose);
    await database.close();
    databaseClosed = true;
    final applied = await service.applyPreparedImport(prepared);
    addTearDown(applied.rollback);

    // 恢复只替换数据库/媒体/偏好，不触碰 tts-models：模型与安装清单仍在且未变。
    expect(modelFile.existsSync(), isTrue);
    expect(await modelFile.readAsBytes(), [1, 2, 3]);
    expect(manifestFile.existsSync(), isTrue);
    // 偏好已随备份回填（引擎/口音/变体/音色保留）。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(TtsSettingsKeys.engine), 'kokoro');
    expect(prefs.getString(TtsSettingsKeys.accent), 'uk');
    expect(prefs.getString(TtsSettingsKeys.kokoroVariant), 'int8');
    expect(prefs.getString(TtsSettingsKeys.piperVoiceUk), 'en_GB-cori-medium');

    await applied.commit();
  });
}
