import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:loop_back/database/app_database.dart';
import 'package:loop_back/services/app_logger.dart';
import 'package:loop_back/services/bundled_example_installer.dart';
import 'package:loop_back/utils/app_data_dir.dart';

AppDatabase _createDb() {
  return AppDatabase(
    NativeDatabase.memory(
      setup: (db) {
        db.execute('PRAGMA foreign_keys = ON');
      },
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase db;
  late SharedPreferences prefs;
  BundledExampleInstaller installer() {
    return BundledExampleInstaller(db, prefs, assetBundle: _FakeAssets());
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'bundled_example_installer_',
    );
    appDataDirectoryOverride = tempDir;
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = _createDb();
    AppLogger.instance.clear();
  });

  tearDown(() async {
    appDataDirectoryOverride = null;
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('空库首次安装 6 条带完整字幕的示例', () async {
    await installer().installOnFirstLaunch();

    final collections = await db.collectionDao.getAllActive();
    expect(collections, hasLength(1));
    expect(collections.single.id, BundledExampleInstaller.collectionId);
    expect(collections.single.name, 'Examples');

    final audioIds = await db.collectionDao.getAudioIds(
      BundledExampleInstaller.collectionId,
    );
    expect(audioIds, [
      'bundled-example-audio-a1',
      'bundled-example-audio-a2',
      'bundled-example-audio-b1',
      'bundled-example-audio-b2',
      'bundled-example-audio-c1',
      'bundled-example-audio-c2',
    ]);

    final items = await db.audioItemDao.getAllActive();
    expect(items, hasLength(6));
    for (final item in items) {
      expect(item.audioPath, startsWith('audios/'));
      expect(item.transcriptPath, isNull);
      expect(item.transcriptSrt, isNotEmpty);
      expect(item.wordTimestampsJson, isNotEmpty);
      expect(item.transcriptSource, 1);
      expect(item.transcriptLanguage, 'en');
      expect(await File('${tempDir.path}/${item.audioPath}').exists(), isTrue);
    }
    final a1 = await db.audioItemDao.getById('bundled-example-audio-a1');
    expect(a1!.name, 'A1 - Class Information');
    expect(a1.totalDuration, 32);
    expect(a1.sentenceCount, 7);
    expect(a1.wordCount, 56);
    expect(a1.transcriptSrt, contains('Before we begin'));
    expect(a1.wordTimestampsJson, contains('"Before"'));
    expect(prefs.getBool('bundled_example_installed'), isTrue);
    expect(AppLogger.instance.entries.last.message, '安装完成：6 条示例已写入');
  });

  test('已安装示例后再次启动时跳过安装', () async {
    await installer().installOnFirstLaunch();
    final audioFile = File('${tempDir.path}/audios/A1 - Class Information.m4a');
    await audioFile.writeAsString('user-edited');

    await installer().installOnFirstLaunch();

    expect(await db.audioItemDao.getAllActive(), hasLength(6));
    expect(await audioFile.readAsString(), 'user-edited');
    expect(AppLogger.instance.entries.last.message, '安装跳过：此前已处理');
  });

  test('用户手动删光示例后不会重新安装', () async {
    await installer().installOnFirstLaunch();
    await db.audioItemDao.hardDeleteMany({
      'bundled-example-audio-a1',
      'bundled-example-audio-a2',
      'bundled-example-audio-b1',
      'bundled-example-audio-b2',
      'bundled-example-audio-c1',
      'bundled-example-audio-c2',
    });

    await installer().installOnFirstLaunch();

    expect(await db.audioItemDao.getAllActive(), isEmpty);
    expect(AppLogger.instance.entries.last.message, '安装跳过：此前已处理');
  });

  test('非空用户库且无旧示例时不自动插入 examples', () async {
    final now = DateTime.now();
    await db
        .into(db.audioItems)
        .insert(
          AudioItemsCompanion.insert(
            id: 'user-audio-1',
            name: 'User Audio',
            audioPath: const Value('audios/user.m4a'),
            addedDate: now,
            updatedAt: now,
          ),
        );

    await installer().installOnFirstLaunch();

    final items = await db.audioItemDao.getAllActive();
    expect(items, hasLength(1));
    expect(items.single.id, 'user-audio-1');
    expect(
      await db.collectionDao.getById(BundledExampleInstaller.collectionId),
      isNull,
    );
    expect(prefs.getBool('bundled_example_installed'), isTrue);
    expect(AppLogger.instance.entries.last.message, '安装跳过：已有用户音频，已标记为完成');
  });
}

class _FakeAssets extends AssetBundle {
  static const _assets = {
    'assets/demo/A1 - Class Information.m4a': 'a1',
    'assets/demo/A1 - Class Information.srt': 'Before we begin',
    'assets/demo/A1 - Class Information.words.json': '[{"word":"Before"}]',
    'assets/demo/A2 - Change a meeting time.m4a': 'a2',
    'assets/demo/A2 - Change a meeting time.srt': 'Hi, Anna.',
    'assets/demo/A2 - Change a meeting time.words.json': '[{"word":"Hi,"}]',
    'assets/demo/B1 - Work-life balance.m4a': 'b1',
    'assets/demo/B1 - Work-life balance.srt':
        'Well, in the more traditional workplaces',
    'assets/demo/B1 - Work-life balance.words.json': '[{"word":"Well,"}]',
    'assets/demo/B2 - Incentives.m4a': 'b2',
    'assets/demo/B2 - Incentives.srt': 'Another study by Dan Ariely',
    'assets/demo/B2 - Incentives.words.json': '[{"word":"Another"}]',
    'assets/demo/C1 - Rent a house.m4a': 'c1',
    'assets/demo/C1 - Rent a house.srt': 'We saw the ad in the summer',
    'assets/demo/C1 - Rent a house.words.json': '[{"word":"We"}]',
    'assets/demo/C2 - Conducting yourself.m4a': 'c2',
    'assets/demo/C2 - Conducting yourself.srt':
        'Conducting yourself effectively',
    'assets/demo/C2 - Conducting yourself.words.json':
        '[{"word":"Conducting"}]',
  };

  @override
  Future<ByteData> load(String key) async {
    final value = _assets[key];
    if (value == null) {
      throw StateError('Missing fake asset: $key');
    }
    return ByteData.sublistView(Uint8List.fromList(value.codeUnits));
  }
}
