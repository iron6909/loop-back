/// 目录来源：创建合集时直接选择，空目录可重选，直接子项自然排序并配对字幕。
library;

import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:loop_back/features/audio_import/last_import_directory_store.dart';
import 'package:loop_back/features/audio_import/local_audio_file_picker.dart';
import 'package:loop_back/models/audio_item.dart';
import 'package:loop_back/providers/audio_library_provider.dart';
import 'package:loop_back/utils/app_data_dir.dart';
import 'package:loop_back/widgets/add_audio_dialog.dart';
import 'package:loop_back/screens/collection_screen.dart';
import 'package:loop_back/features/audio_import/audio_import_models.dart';
import 'package:loop_back/features/audio_import/audio_import_provider.dart';
import 'package:loop_back/features/remote_config/remote_config.dart';
import 'package:loop_back/features/remote_config/remote_config_providers.dart';
import 'package:loop_back/widgets/import_audio_selection_list.dart';
import 'package:loop_back/widgets/import_audio_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/providers/shared_preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_app.dart';
import '../helpers/mock_providers.dart';

class _IdleImport extends AudioImportController {
  @override
  AudioImportState build() => const AudioImportIdle();
}

void main() {
  const channel = MethodChannel('top.loop-back/local_audio_picker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Object? directory;

  /// 模拟「按记住的 URI 重列目录」的回包；null 表示授权已失效。
  Object? rememberedDirectory;
  bool rememberedUnavailable = false;
  late SharedPreferences prefs;
  final calls = <String>[];
  setUp(() async {
    calls.clear();
    rememberedDirectory = null;
    rememberedUnavailable = false;
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'pickDirectory') return directory;
      if (call.method == 'listDirectory') {
        if (rememberedUnavailable) {
          throw PlatformException(code: 'directory_unavailable');
        }
        return rememberedDirectory;
      }
      if (call.method == 'readBytes') {
        return Uint8List.fromList(
          '1\n00:00:00,000 --> 00:00:01,000\nHello\n'.codeUnits,
        );
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Widget app({bool directoryOnly = true}) => createTestApp(
    Builder(
      builder: (context) => FilledButton(
        onPressed: () =>
            showImportAudioSheet(context, directoryOnly: directoryOnly),
        child: const Text('Open Import'),
      ),
    ),
    overrides: [
      audioImportControllerProvider.overrideWith(_IdleImport.new),
      sharedPreferencesProvider.overrideWithValue(prefs),
      initialRemoteConfigProvider.overrideWithValue(
        const RemoteConfig(
          version: 1,
          ttlSeconds: 86400,
          context: RemoteConfigContext(),
          features: RemoteConfigFeatures(
            cloudDriveImport: RemoteFeatureConfig(enabled: false),
          ),
        ),
      ),
    ],
  );

  testWidgets('完成后合集列表按当前排序定位新建合集', (tester) async {
    final collections = [
      for (var i = 0; i < 40; i++)
        createTestCollection(id: '$i', name: 'Lesson $i'),
    ];
    await tester.pumpWidget(
      createTestApp(
        CollectionListView(collections: collections, focusedCollectionId: '35'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Lesson 35').hitTestable(), findsOneWidget);
    expect(find.text('Lesson 0').hitTestable(), findsNothing);
  });

  testWidgets('普通音频导入只含文件和链接；目录选择取消后关闭且可重开', (tester) async {
    directory = null;
    await tester.pumpWidget(app(directoryOnly: false));
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    expect(find.text('Import from Folder'), findsNothing);
    expect(find.text('Import from File'), findsOneWidget);
    expect(find.text('Import from Link'), findsOneWidget);
    await tester.pumpWidget(app());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    expect(calls, ['pickDirectory']);
    expect(find.byType(ImportAudioFlowSheet), findsNothing);
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    expect(calls, ['pickDirectory', 'pickDirectory']);
    expect(find.byType(ImportAudioSelectionList), findsNothing);
  });

  testWidgets('空目录不进入确认页，错误与重选入口同时保留', (tester) async {
    directory = {'name': 'Empty', 'children': <Object?>[]};
    await tester.pumpWidget(app());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    expect(find.text('This folder has no importable audio'), findsOneWidget);
    expect(find.byKey(const ValueKey('reselect-directory')), findsOneWidget);
    expect(find.byType(ImportAudioSelectionList), findsNothing);
    // 空目录不得遗留旧的单选项入口。
    expect(find.byKey(const ValueKey('import-option-directory')), findsNothing);
  });

  testWidgets('有上次文件夹时先给一键入口，点开直接进确认页', (tester) async {
    await prefs.setString(
      LastImportDirectoryStore.uriKey,
      'content://tree/lessons',
    );
    await prefs.setString(LastImportDirectoryStore.nameKey, 'Lessons');
    rememberedDirectory = {
      'uri': 'content://tree/lessons',
      'name': 'Lessons',
      'children': [
        {
          'uri': 'content://tree/1',
          'name': '1.mp3',
          'size': 3,
          'isDirectory': false,
        },
      ],
    };

    await tester.pumpWidget(app());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();

    // 不再重新走系统选择器，也不再经过只有一项的旧入口页。
    expect(calls, isEmpty);
    expect(find.text('Last import'), findsOneWidget);
    expect(find.byKey(const ValueKey('remembered-directory')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remembered-directory')));
    await tester.pumpAndSettle();

    expect(calls, ['listDirectory']);
    expect(find.text('Confirm import'), findsOneWidget);
    expect(find.byType(ImportAudioSelectionList), findsOneWidget);
  });

  testWidgets('上次文件夹失效时清空记忆并退回系统选择器', (tester) async {
    await prefs.setString(
      LastImportDirectoryStore.uriKey,
      'content://tree/lessons',
    );
    await prefs.setString(LastImportDirectoryStore.nameKey, 'Lessons');
    rememberedUnavailable = true;
    directory = null;

    await tester.pumpWidget(app());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('remembered-directory')));
    await tester.pumpAndSettle();

    expect(calls, ['listDirectory', 'pickDirectory']);
    expect(prefs.getString(LastImportDirectoryStore.uriKey), isNull);
    expect(prefs.getString(LastImportDirectoryStore.nameKey), isNull);
  });

  testWidgets('只读直接文件，按自然序预览且匹配同名字幕', (tester) async {
    directory = {
      'name': 'Lessons',
      'children': [
        {
          'uri': 'content://tree/10',
          'name': '10.mp3',
          'size': 10,
          'isDirectory': false,
        },
        {
          'uri': 'content://tree/2',
          'name': '2.mp3',
          'size': 2,
          'isDirectory': false,
        },
        {
          'uri': 'content://tree/srt',
          'name': '2.srt',
          'size': 30,
          'isDirectory': false,
        },
        {
          'uri': 'content://tree/jpg',
          'name': 'cover.jpg',
          'size': 1,
          'isDirectory': false,
        },
        {
          'uri': 'content://tree/sub',
          'name': 'sub',
          'size': 0,
          'isDirectory': true,
        },
      ],
    };
    await tester.pumpWidget(app());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    final list = tester.widget<ImportAudioSelectionList>(
      find.byType(ImportAudioSelectionList),
    );
    expect(list.items.map((item) => item.displayName), ['2.mp3', '10.mp3']);
    expect(list.items.first.hasSubtitle, isTrue);
    // 文件夹名同时出现在页头与「合集名」汇总行。
    expect(find.text('Lessons'), findsWidgets);
    expect(calls, ['pickDirectory', 'readBytes']);
    expect(find.text('Select Collection'), findsNothing);
  });

  testWidgets('确认页点「更换」后取消选择，仍留在原确认页', (tester) async {
    directory = {
      'name': 'Lessons',
      'children': [
        {
          'uri': 'content://tree/1',
          'name': '1.mp3',
          'size': 3,
          'isDirectory': false,
        },
      ],
    };
    await tester.pumpWidget(app());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm import'), findsOneWidget);

    // 第二次选目录被取消（回包 null），不应关掉面板也不应丢掉已选目录。
    directory = null;
    await tester.tap(find.byKey(const ValueKey('replace-directory')));
    await tester.pumpAndSettle();

    expect(calls, ['pickDirectory', 'pickDirectory']);
    expect(find.text('Confirm import'), findsOneWidget);
    expect(find.byType(ImportAudioSelectionList), findsOneWidget);
  });

  testWidgets('全重复导入仍提交合集；事务失败可重试且不会重新复制文件', (tester) async {
    final dataDir = Directory.systemTemp.createTempSync('directory_retry_');
    appDataDirectoryOverride = dataDir;
    addTearDown(() {
      appDataDirectoryOverride = null;
      dataDir.deleteSync(recursive: true);
    });
    final existing = AudioItem(
      id: 'existing',
      name: 'Existing',
      addedDate: DateTime(2026),
      originalAudioSha256:
          '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a',
    );
    var commits = 0;
    late Completer<void> settled;
    var done = false;
    final attemptedIds = <List<String>>[];
    await tester.pumpWidget(
      createTestApp(
        AddAudioDialog(
          embedded: true,
          initialDirectory: PickedAudioDirectory(
            name: 'Lessons',
            files: [
              PlatformFile(
                name: '2.mp3',
                size: 4,
                bytes: Uint8List.fromList([1, 2, 3, 4]),
              ),
            ],
          ),
          onImported: (ids) async {
            attemptedIds.add(ids);
            commits++;
            if (commits == 1) {
              settled.complete();
              throw StateError('database busy');
            }
          },
          onDone: () => done = true,
        ),
        overrides: [
          audioLibraryProvider.overrideWith(
            () => TestAudioLibrary(AudioLibraryState(audioItems: [existing])),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    // 指纹在 isolate 中计算，真实 I/O 必须离开 widget fake-async 区。
    await tester.runAsync(() async {
      settled = Completer<void>();
      await tester.tap(find.byType(FilledButton));
      await settled.future.timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(attemptedIds, [
      ['existing'],
    ]);
    expect(done, isFalse);
    // 删掉已落盘文件：重试若错误地重新复制会再次写出，便于检测回归。
    final audioDir = Directory('${dataDir.path}/audios');
    audioDir.deleteSync(recursive: true);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(commits, 2);
    expect(audioDir.existsSync(), isFalse);
    expect(find.text('Done'), findsOneWidget);
    await tester.tap(find.text('Done'));
    expect(done, isTrue);
  });

  testWidgets('目录内某项复制失败仍处理后续项；全部失败不提交合集', (tester) async {
    final dataDir = Directory.systemTemp.createTempSync('directory_failed_');
    appDataDirectoryOverride = dataDir;
    addTearDown(() {
      appDataDirectoryOverride = null;
      dataDir.deleteSync(recursive: true);
    });
    var commits = 0;
    final copied = <String>[];
    late Completer<void> copiesDone;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'copyToFile') {
        if (call.arguments case {'uri': final String uri}) {
          copied.add(uri);
          throw PlatformException(code: 'read_failed');
        }
      }
      return null;
    });
    await tester.pumpWidget(
      createTestApp(
        AddAudioDialog(
          embedded: true,
          initialDirectory: PickedAudioDirectory(
            name: 'Failed',
            files: [
              PlatformFile(name: '1.mp3', size: 1, identifier: 'content://1'),
              PlatformFile(name: '2.mp3', size: 1, identifier: 'content://2'),
            ],
            ignoredDirectories: 2,
            unsupportedCount: 3,
          ),
          onImported: (_) async {
            commits++;
          },
          onImportingChanged: (busy) {
            if (!busy && !copiesDone.isCompleted) copiesDone.complete();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      copiesDone = Completer<void>();
      await tester.tap(find.byType(FilledButton));
      await copiesDone.future.timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    expect(copied, ['content://1', 'content://2']);
    expect(commits, 0);
    final list = tester.widget<ImportAudioSelectionList>(
      find.byType(ImportAudioSelectionList),
    );
    expect(list.summary?.failedCount, 2);
    expect(find.text('Subfolders skipped: 2'), findsOneWidget);
    expect(find.text('Unsupported files ignored: 3'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });
}
