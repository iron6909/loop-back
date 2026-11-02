/// 目录来源：从合集入口可见，空目录保留来源页，直接子项自然排序并配对字幕。
library;

import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:echo_loop/features/audio_import/local_audio_file_picker.dart';
import 'package:echo_loop/models/audio_item.dart';
import 'package:echo_loop/providers/audio_library_provider.dart';
import 'package:echo_loop/utils/app_data_dir.dart';
import 'package:echo_loop/widgets/add_audio_dialog.dart';
import 'package:echo_loop/screens/collection_screen.dart';
import 'package:echo_loop/features/audio_import/audio_import_models.dart';
import 'package:echo_loop/features/audio_import/audio_import_provider.dart';
import 'package:echo_loop/features/remote_config/remote_config.dart';
import 'package:echo_loop/features/remote_config/remote_config_providers.dart';
import 'package:echo_loop/widgets/import_audio_selection_list.dart';
import 'package:echo_loop/widgets/import_audio_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';
import '../helpers/mock_providers.dart';

class _IdleImport extends AudioImportController {
  @override
  AudioImportState build() => const AudioImportIdle();
}

void main() {
  const channel = MethodChannel('top.echo-loop/local_audio_picker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Object? directory;
  final calls = <String>[];
  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'pickDirectory') return directory;
      if (call.method == 'readBytes') {
        return Uint8List.fromList(
          '1\n00:00:00,000 --> 00:00:01,000\nHello\n'.codeUnits,
        );
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Widget app({bool allowDirectory = true}) => createTestApp(
    ImportAudioFlowSheet(allowDirectoryImport: allowDirectory),
    overrides: [
      audioImportControllerProvider.overrideWith(_IdleImport.new),
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

  testWidgets('文件夹来源仅在合集入口显示；取消后仍可重新选择', (tester) async {
    directory = null;
    await tester.pumpWidget(app(allowDirectory: false));
    await tester.pumpAndSettle();
    expect(find.text('Import from Folder'), findsNothing);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from Folder'));
    await tester.pumpAndSettle();
    expect(find.text('Import from Folder'), findsOneWidget);
    expect(find.byType(ImportAudioSelectionList), findsNothing);
  });

  testWidgets('空目录不进入导入面板，错误与重选入口同时保留', (tester) async {
    directory = {'name': 'Empty', 'children': <Object?>[]};
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from Folder'));
    await tester.pumpAndSettle();
    expect(find.text('This folder has no importable audio'), findsOneWidget);
    expect(find.text('Import from Folder'), findsOneWidget);
    expect(find.byType(ImportAudioSelectionList), findsNothing);
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
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from Folder'));
    await tester.pumpAndSettle();
    final list = tester.widget<ImportAudioSelectionList>(
      find.byType(ImportAudioSelectionList),
    );
    expect(list.items.map((item) => item.displayName), ['2.mp3', '10.mp3']);
    expect(list.items.first.hasSubtitle, isTrue);
    expect(find.text('Lessons'), findsOneWidget);
    expect(calls, ['pickDirectory', 'readBytes']);
    expect(find.text('Select Collection'), findsNothing);
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
