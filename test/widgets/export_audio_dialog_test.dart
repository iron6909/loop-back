import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/widgets/dialogs/export_audio_dialog.dart';
import 'package:loop_back/l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// 包装测试 Widget，提供 MaterialApp 和国际化支持
Widget _buildTestApp({required Widget child}) {
  return MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: Scaffold(body: child),
  );
}

void main() {
  group('ExportAudioDialog', () {
    testWidgets('有字幕时两个 checkbox 都可用', (tester) async {
      await tester.pumpWidget(
        _buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  showExportAudioDialog(context: context, hasTranscript: true),
              child: const Text('Open'),
            ),
          ),
        ),
      );

      // 打开对话框
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // 验证两个 checkbox 都存在
      expect(find.text('Audio'), findsOneWidget);
      expect(find.text('Subtitles'), findsOneWidget);

      // 两个 checkbox 都应可点击
      final checkboxes = find.byType(Checkbox);
      expect(checkboxes, findsNWidgets(2));
    });

    testWidgets('isVideo 时标题与媒体选项文案用「视频」', (tester) async {
      await tester.pumpWidget(
        _buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showExportAudioDialog(
                context: context,
                hasTranscript: true,
                isVideo: true,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // 标题 + 确认按钮都为 Export Video；媒体选项为 Video；不出现 Audio 文案。
      expect(find.text('Export Video'), findsNWidgets(2));
      expect(find.text('Video'), findsOneWidget);
      expect(find.text('Audio'), findsNothing);
      expect(find.text('Subtitles'), findsOneWidget);
    });

    testWidgets('无字幕时字幕 checkbox disabled', (tester) async {
      await tester.pumpWidget(
        _buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  showExportAudioDialog(context: context, hasTranscript: false),
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // 字幕 checkbox 应该是 disabled 且未选中
      final checkboxes = tester
          .widgetList<Checkbox>(find.byType(Checkbox))
          .toList();
      // 第一个是音频，第二个是字幕
      expect(checkboxes[1].onChanged, isNull); // disabled
      expect(checkboxes[1].value, false); // 未选中
    });

    testWidgets('默认只选中字幕时导出按钮可用', (tester) async {
      await tester.pumpWidget(
        _buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  showExportAudioDialog(context: context, hasTranscript: true),
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // 导出按钮应该可用（字幕默认选中）
      final exportButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Export Audio'),
      );
      expect(exportButton.onPressed, isNotNull);
    });

    testWidgets('全部未选时导出按钮 disabled', (tester) async {
      await tester.pumpWidget(
        _buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  showExportAudioDialog(context: context, hasTranscript: true),
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // 取消选中字幕（默认选中的）
      await tester.tap(find.text('Subtitles'));
      await tester.pumpAndSettle();

      // 导出按钮应该 disabled
      final exportButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Export Audio'),
      );
      expect(exportButton.onPressed, isNull);
    });

    testWidgets('取消返回 null', (tester) async {
      ExportAudioSelection? result;

      await tester.pumpWidget(
        _buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showExportAudioDialog(
                  context: context,
                  hasTranscript: true,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets('确认返回正确的 selection', (tester) async {
      ExportAudioSelection? result;

      await tester.pumpWidget(
        _buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showExportAudioDialog(
                  context: context,
                  hasTranscript: true,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // 勾选音频（字幕已默认选中）
      await tester.tap(find.text('Audio'));
      await tester.pumpAndSettle();

      // 点击导出
      await tester.tap(find.widgetWithText(FilledButton, 'Export Audio'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.includeAudio, true);
      expect(result!.includeTranscript, true);
    });

    testWidgets('无字幕时只能导出音频', (tester) async {
      ExportAudioSelection? result;

      await tester.pumpWidget(
        _buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showExportAudioDialog(
                  context: context,
                  hasTranscript: false,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // 导出按钮应 disabled（无字幕时默认都未选）
      var exportButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Export Audio'),
      );
      expect(exportButton.onPressed, isNull);

      // 勾选音频
      await tester.tap(find.text('Audio'));
      await tester.pumpAndSettle();

      // 现在可以导出
      await tester.tap(find.widgetWithText(FilledButton, 'Export Audio'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.includeAudio, true);
      expect(result!.includeTranscript, false);
    });
  });
}
