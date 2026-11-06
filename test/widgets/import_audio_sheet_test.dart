import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo_loop/features/audio_import/audio_import_models.dart';
import 'package:echo_loop/features/audio_import/audio_import_provider.dart';
import 'package:echo_loop/models/audio_item.dart';
import 'package:echo_loop/providers/audio_library_provider.dart';
import 'package:echo_loop/providers/collection_provider.dart';
import 'package:echo_loop/providers/settings_provider.dart';
import 'package:echo_loop/widgets/import_audio_selection_list.dart';
import 'package:echo_loop/widgets/import_audio_sheet.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:file_picker/file_picker.dart';

import '../helpers/mock_providers.dart';
import '../helpers/test_app.dart';

class _ImmediateAudioImportController extends AudioImportController {
  _ImmediateAudioImportController({this.fail = false});

  final bool fail;

  @override
  AudioImportState build() => const AudioImportIdle();

  @override
  Future<AudioItem?> importFromUrl(String url, {String? collectionId}) async {
    if (fail) {
      state = const AudioImportFailed(
        AudioImportException(AudioImportFailureCode.invalidUrl, 'invalid'),
      );
      return null;
    }
    final item = AudioItem(
      id: 'url-audio',
      name: 'URL Audio',
      audioPath: 'audios/imported/url.mp3',
      addedDate: DateTime(2026, 1, 1),
    );
    state = AudioImportCompleted(item);
    return item;
  }
}

class _PendingAudioImportController extends AudioImportController {
  final Completer<AudioItem?> _completion = Completer<AudioItem?>();
  bool cancellationRequested = false;

  @override
  AudioImportState build() => const AudioImportIdle();

  @override
  Future<AudioItem?> importFromUrl(String url, {String? collectionId}) {
    state = AudioImportDownloading(displayName: url, progress: 0.4);
    return _completion.future;
  }

  @override
  Future<void> cancel() async {
    cancellationRequested = true;
    state = const AudioImportIdle();
    if (!_completion.isCompleted) _completion.complete(null);
  }
}

class _RecordingFilePicker extends FilePicker {
  _RecordingFilePicker({this.result});

  /// 选择器回传的结果；null 表示用户取消。
  final FilePickerResult? result;

  bool? lastAllowMultiple;
  int pickCount = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    @Deprecated(
      'allowCompression is deprecated and has no effect. Use compressionQuality instead.',
    )
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    lastAllowMultiple = allowMultiple;
    pickCount++;
    return result;
  }
}

Widget _buildApp({
  bool failImport = false,
  Locale locale = const Locale('en'),
  List<Override> overrides = const <Override>[],
}) {
  return createTestApp(
    Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => showImportAudioSheet(context),
            child: const Text('Open Import'),
          ),
        ),
      ),
    ),
    overrides: [
      analyticsOverride(),
      appSettingsProvider.overrideWith(
        () => TestAppSettings(AppSettingsState(locale: locale)),
      ),
      audioLibraryProvider.overrideWith(() => TestAudioLibrary()),
      collectionListProvider.overrideWith(() => TestCollectionList()),
      audioImportControllerProvider.overrideWith(
        () => _ImmediateAudioImportController(fail: failImport),
      ),
      ...overrides,
    ],
    locale: locale,
  );
}

void main() {
  void mockClipboardText(String? text) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return text == null ? null : <String, Object?>{'text': text};
          }
          return null;
        });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('导入入口只提供服务商与本机来源，不展示网盘', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Import from File'), findsOneWidget);
    expect(find.text('Import from Link'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('import-option-cloud-drive')),
      findsNothing,
    );
  });

  testWidgets('导入列表在固定高度内滚动且不溢出', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await tester.pumpWidget(
      createTestApp(
        Scaffold(
          body: SizedBox(
            height: 260,
            child: ImportAudioSelectionList(
              maxHeight: double.infinity,
              progress: const AudioImportSelectionProgress(
                label: '正在导入 12/30：audio-12.mp3',
                value: 0.8,
              ),
              items: [
                for (var i = 0; i < 30; i++)
                  AudioImportSelectionItem(
                    id: '$i',
                    displayName: 'audio-$i.mp3',
                    fileSize: 1024 * 1024,
                    hasSubtitle: i.isEven,
                    status: i == 12
                        ? AudioImportSelectionStatus.importing
                        : i < 12
                        ? AudioImportSelectionStatus.added
                        : AudioImportSelectionStatus.pending,
                  ),
              ],
            ),
          ),
        ),
        overrides: [
          analyticsOverride(),
          appSettingsProvider.overrideWith(
            () => TestAppSettings(AppSettingsState(locale: const Locale('zh'))),
          ),
        ],
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('audio-0.mp3'), findsOneWidget);
    expect(find.text('正在导入 12/30：audio-12.mp3'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('导入列表正在导入行显示下载速度百分比和失败摘要', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        Scaffold(
          body: SizedBox(
            width: 360,
            child: ImportAudioSelectionList(
              progress: const AudioImportSelectionProgress(
                label: '正在导入 1/2：002-第一周-002-W1-英国文化拓展-很长很长的文件名.mp4',
                value: 0.5,
                progressPercent: 50,
                speedBytesPerSecond: 512 * 1024,
              ),
              summary: const AudioImportSelectionSummary(
                addedCount: 1,
                subtitleCount: 0,
                skippedCount: 0,
                failedCount: 1,
              ),
              items: const [
                AudioImportSelectionItem(
                  id: 'lesson',
                  displayName: '002-第一周-002-W1-英国文化拓展-很长很长的文件名.mp4',
                  fileSize: 2 * 1024 * 1024,
                  hasSubtitle: false,
                  status: AudioImportSelectionStatus.importing,
                ),
                AudioImportSelectionItem(
                  id: 'failed',
                  displayName: 'failed.mp4',
                  fileSize: 1024,
                  hasSubtitle: false,
                  status: AudioImportSelectionStatus.failed,
                  failureMessage: 'Connection terminated during handshake',
                ),
              ],
            ),
          ),
        ),
        overrides: [
          analyticsOverride(),
          appSettingsProvider.overrideWith(
            () => TestAppSettings(AppSettingsState(locale: const Locale('zh'))),
          ),
        ],
        locale: const Locale('zh'),
      ),
    );

    expect(find.text('512.0 KB/s · 50%'), findsOneWidget);
    expect(find.textContaining('正在导入 1/2：002-第一周'), findsOneWidget);
    expect(find.textContaining('成功导入 1 个素材'), findsOneWidget);
    expect(find.text('失败 1 个'), findsOneWidget);
    expect(find.byIcon(Icons.cancel_rounded), findsNWidgets(2));
  });

  testWidgets('导入列表速度采样为空时仍保留右侧速度占位', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        Scaffold(
          body: SizedBox(
            width: 360,
            child: ImportAudioSelectionList(
              progress: const AudioImportSelectionProgress(
                label: '正在导入 1/3：lesson.mp4',
                value: 0.15,
                progressPercent: 15,
              ),
              items: const [
                AudioImportSelectionItem(
                  id: 'lesson',
                  displayName: 'lesson.mp4',
                  fileSize: 2 * 1024 * 1024,
                  hasSubtitle: false,
                  status: AudioImportSelectionStatus.importing,
                ),
              ],
            ),
          ),
        ),
        overrides: [
          analyticsOverride(),
          appSettingsProvider.overrideWith(
            () => TestAppSettings(AppSettingsState(locale: const Locale('zh'))),
          ),
        ],
        locale: const Locale('zh'),
      ),
    );

    expect(find.text('0 B/s · 15%'), findsOneWidget);
  });

  testWidgets('导入列表未开始导入时可显示删除入口', (tester) async {
    final removedIds = <String>[];
    await tester.pumpWidget(
      createTestApp(
        Scaffold(
          body: ImportAudioSelectionList(
            onRemove: removedIds.add,
            items: const [
              AudioImportSelectionItem(
                id: 'local-audio',
                displayName: 'local.mp3',
                fileSize: 1024,
                hasSubtitle: true,
              ),
            ],
          ),
        ),
        overrides: [
          analyticsOverride(),
          appSettingsProvider.overrideWith(
            () => TestAppSettings(AppSettingsState(locale: const Locale('zh'))),
          ),
        ],
      ),
    );

    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline));
    expect(removedIds, ['local-audio']);
  });

  testWidgets('导入方式入口使用独立边框分隔', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();

    final localOption = find.byKey(const ValueKey('import-option-local-file'));
    final linkOption = find.byKey(const ValueKey('import-option-direct-url'));
    expect(localOption, findsOneWidget);
    expect(linkOption, findsOneWidget);

    final localMaterial = tester.widget<Material>(
      find.descendant(of: localOption, matching: find.byType(Material)),
    );
    final linkMaterial = tester.widget<Material>(
      find.descendant(of: linkOption, matching: find.byType(Material)),
    );
    final localShape = localMaterial.shape;
    final linkShape = linkMaterial.shape;
    expect(localShape, isA<RoundedRectangleBorder>());
    expect(linkShape, isA<RoundedRectangleBorder>());
    expect(
      (localShape! as RoundedRectangleBorder).side.style,
      BorderStyle.solid,
    );
    expect(
      (linkShape! as RoundedRectangleBorder).side.style,
      BorderStyle.solid,
    );

    final localBottom = tester.getBottomLeft(localOption).dy;
    final linkTop = tester.getTopLeft(linkOption).dy;
    expect(linkTop - localBottom, 8);
  });

  testWidgets('本地文件入口允许一次选择多个音频和字幕文件', (tester) async {
    final picker = _RecordingFilePicker();
    FilePicker.platform = picker;

    await tester.pumpWidget(_buildApp(locale: const Locale('zh')));
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('从本地文件导入'));
    await tester.pumpAndSettle();

    expect(picker.lastAllowMultiple, isTrue);
  });

  testWidgets('本地文件入口不显示说明提示', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();

    // 本地文件入口已移除说明文案。
    expect(
      find.text('Choose media files from your phone or cloud drive'),
      findsNothing,
    );
    expect(find.text('Import from File'), findsOneWidget);
    expect(find.text('Import from Link'), findsOneWidget);
  });

  testWidgets('链接入口显示 URL 表单且空输入禁用提交', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from Link'));
    await tester.pumpAndSettle();

    expect(find.text('Audio link'), findsOneWidget);
    expect(find.text('Paste Link'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).autofocus, isFalse);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Download and Import'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('链接导入表单弱化输入提示样式', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from Link'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    final fieldContext = tester.element(find.byType(TextField));
    final theme = Theme.of(fieldContext);

    expect(field.style?.fontSize, theme.textTheme.bodyMedium?.fontSize);
    expect(
      field.decoration?.hintStyle?.fontSize,
      theme.textTheme.bodyMedium?.fontSize,
    );
    expect(
      field.decoration?.hintStyle?.color,
      theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.52),
    );
    expect(
      field.decoration?.labelStyle?.fontSize,
      theme.textTheme.bodySmall?.fontSize,
    );
    expect(
      field.decoration?.floatingLabelStyle?.color,
      theme.colorScheme.primary.withValues(alpha: 0.78),
    );
  });

  testWidgets('本地文件只选中字幕时提示未选择音频且可重新选择', (tester) async {
    // 回归防线：字幕不能单独导入，此前这种情况面板既无提示、底部按钮又是禁用的
    // 「导入」，用户在 embedded 面板里没有任何重新唤起选择器的入口。
    final picker = _RecordingFilePicker(
      result: FilePickerResult([
        PlatformFile(path: '/cache/0/talk.srt', name: 'talk.srt', size: 46),
      ]),
    );
    FilePicker.platform = picker;

    await tester.pumpWidget(_buildApp());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from File'));
    await tester.pumpAndSettle();

    expect(find.text('No audio file selected'), findsOneWidget);

    final button = find.widgetWithText(FilledButton, 'Select Audio File');
    expect(button, findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);

    // 点击可再次唤起选择器。
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(picker.pickCount, 2);
  });

  testWidgets('本地文件删空已选列表后可重新选择', (tester) async {
    final picker = _RecordingFilePicker(
      result: FilePickerResult([
        PlatformFile(path: '/cache/0/talk.mp3', name: 'talk.mp3', size: 2048),
      ]),
    );
    FilePicker.platform = picker;

    await tester.pumpWidget(_buildApp());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from File'));
    await tester.pumpAndSettle();

    expect(find.text('talk.mp3'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Select Audio File'),
      findsNothing,
    );

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('talk.mp3'), findsNothing);
    final button = find.widgetWithText(FilledButton, 'Select Audio File');
    expect(button, findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
  });

  testWidgets('链接导入页可从剪切板粘贴链接并启用提交', (tester) async {
    mockClipboardText('https://example.com/audio.mp3');
    await tester.pumpWidget(_buildApp());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from Link'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Paste Link'));
    await tester.pump();

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, 'https://example.com/audio.mp3');
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Download and Import'),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('链接导入页剪切板没有链接时显示内联提示', (tester) async {
    mockClipboardText('not a link');
    await tester.pumpWidget(_buildApp());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from Link'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Paste Link'));
    await tester.pump();

    expect(find.text('Clipboard does not have a valid link'), findsOneWidget);
  });

  testWidgets('链接导入页可返回导入方式选择页', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from Link'));
    await tester.pumpAndSettle();

    expect(find.text('Audio link'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Import from File'), findsOneWidget);
    expect(find.text('Import from Link'), findsOneWidget);
    expect(find.text('Audio link'), findsNothing);
  });

  testWidgets('链接导入页空闲时底部返回按钮回到导入方式选择页', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from Link'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Back'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();

    expect(find.text('Import Audio'), findsOneWidget);
    expect(find.text('Import from File'), findsOneWidget);
    expect(find.text('Import from Link'), findsOneWidget);
    expect(find.text('Audio link'), findsNothing);
  });

  testWidgets('链接导入失败时留在表单并显示内联错误', (tester) async {
    await tester.pumpWidget(_buildApp(failImport: true));
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from Link'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'bad-url');
    await tester.pump();
    await tester.tap(find.text('Download and Import'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid audio link'), findsOneWidget);
    expect(find.text('Audio link'), findsOneWidget);
  });

  testWidgets('导入中锁定返回和遮罩关闭，主按钮取消后恢复导航', (tester) async {
    final controller = _PendingAudioImportController();
    await tester.pumpWidget(
      _buildApp(
        overrides: [
          audioImportControllerProvider.overrideWith(() => controller),
        ],
      ),
    );
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from Link'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.com/a.mp3');
    await tester.pump();
    await tester.tap(find.text('Download and Import'));
    await tester.pump();

    expect(find.text('Cancel Import'), findsOneWidget);
    expect(find.byTooltip('Close'), findsNothing);
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.tapAt(const Offset(2, 2));
    await tester.pump();

    expect(find.text('Audio link'), findsOneWidget);
    expect(controller.cancellationRequested, isFalse);

    await tester.tap(find.text('Cancel Import'));
    await tester.pumpAndSettle();

    expect(controller.cancellationRequested, isTrue);
    expect(find.text('Audio link'), findsOneWidget);
    expect(find.text('Cancel Import'), findsNothing);
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
  });

  testWidgets('链接导入成功后仅显示完成确认，不再提示添加字幕', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.tap(find.text('Open Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from Link'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'https://example.com/a.mp3');
    await tester.pump();
    await tester.tap(find.text('Download and Import'));
    await tester.pumpAndSettle();

    expect(find.text('Import complete'), findsOneWidget);
    // 完成页展示成功导入计数与其中带字幕数量。
    expect(find.text('1 items imported'), findsOneWidget);
    expect(find.text('0 with subtitles'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    // 字幕已自动匹配，完成页不再提示添加字幕。
    expect(find.text('Add Subtitle'), findsNothing);
    expect(find.text('Add a subtitle now for learning?'), findsNothing);
  });
}
