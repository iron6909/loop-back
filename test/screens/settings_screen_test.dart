/// SettingsScreen 测试
///
/// 测试设置页面的渲染和交互。
library;

import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:loop_back/providers/developer_options_provider.dart';
import 'package:loop_back/providers/offline_asr_settings_provider.dart';
import 'package:loop_back/providers/tts/tts_settings_provider.dart';
import 'package:loop_back/screens/settings_screen.dart';
import 'package:loop_back/providers/settings_provider.dart';
import 'package:loop_back/providers/audio_library_provider.dart';
import 'package:loop_back/providers/collection_provider.dart';
import 'package:loop_back/features/user_region/user_region_providers.dart';
import 'package:loop_back/providers/listening_practice/listening_practice_provider.dart';
import 'package:loop_back/providers/audio_engine/audio_engine_provider.dart';
import 'package:loop_back/providers/package_info_provider.dart';
import 'package:loop_back/services/tts/tts_engine.dart';
import 'package:loop_back/theme/app_theme.dart';

import '../helpers/mock_providers.dart';
import '../helpers/test_app.dart';

void main() {
  final testPackageInfo = PackageInfo(
    appName: 'LoopBack',
    packageName: 'top.loop-back',
    version: '1.0.0',
    buildNumber: '1',
  );

  // 词典设置等同步读取 SharedPreferences 的 provider 需注入实例
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  List<Override> buildOverrides({
    AppSettingsState settings = const AppSettingsState(),
    bool showDeveloperOptions = true,
    bool showOfflineAsrSection = false,
    OfflineAsrSettingsState? offlineAsrState,
    TtsSettings ttsSettings = const TtsSettings(),
    PackageInfo? packageInfo,
    bool isChinaUser = false,
    StateProvider<bool>? simulatedChinaUserProvider,
  }) {
    const recommendedModel = AsrModelInfo(
      id: 'whisper-base-en-int8',
      displayName: 'Whisper Base.en',
      type: AsrModelType.whisper,
    );
    return [
      ...learningSettingsOverrides(prefs: prefs),
      appSettingsProvider.overrideWith(() => TestAppSettings(settings)),
      initialTtsSettingsProvider.overrideWithValue(ttsSettings),
      showDeveloperOptionsProvider.overrideWith(
        () => _TestDeveloperOptions(showDeveloperOptions),
      ),
      showOfflineAsrSectionProvider.overrideWithValue(showOfflineAsrSection),
      recommendedAsrModelProvider.overrideWithValue(recommendedModel),
      initialOfflineAsrSettingsStateProvider.overrideWithValue(
        offlineAsrState ??
            OfflineAsrSettingsState(recommendedModel: recommendedModel),
      ),
      audioLibraryProvider.overrideWith(() => TestAudioLibrary()),
      collectionListProvider.overrideWith(() => TestCollectionList()),
      listeningPracticeProvider.overrideWith(() => TestListeningPractice()),
      audioEngineProvider.overrideWith(() => TestAudioEngine()),
      packageInfoProvider.overrideWithValue(packageInfo ?? testPackageInfo),
      isChinaUserProvider.overrideWith((ref) {
        final simulatedProvider = simulatedChinaUserProvider;
        return simulatedProvider == null
            ? isChinaUser
            : ref.watch(simulatedProvider);
      }),
      analyticsOverride(),
    ];
  }

  group('SettingsScreen', () {
    const settingsSvgAssets = [
      'assets/icon/artist-palette.svg',
      'assets/icon/locale.svg',
      'assets/icon/speak.svg',
      'assets/icon/bell.svg',
      'assets/icon/book-shelf.svg',
      'assets/icon/microphone.svg',
      'assets/icon/speaker.svg',
      'assets/icon/play-pause.svg',
      'assets/icon/locale-1.svg',
      'assets/icon/diskette.svg',
      'assets/icon/trash-bin.svg',
      'assets/icon/refresh.svg',
      'assets/icon/documents.svg',
      'assets/icon/lock.svg',
      'assets/icon/feedback.svg',
      'assets/icon/help.svg',
      'assets/icon/group.svg',
    ];

    Finder findSvgAsset(String assetName) {
      return find.byWidgetPredicate(
        (widget) =>
            widget is SvgPicture &&
            widget.bytesLoader is SvgAssetLoader &&
            (widget.bytesLoader as SvgAssetLoader).assetName == assetName,
      );
    }

    group('渲染', () {
      testWidgets('AI 服务标题与相邻设置项对齐', (tester) async {
        await tester.pumpWidget(
          createTestScreen(const SettingsScreen(), overrides: buildOverrides()),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Playback Settings'));
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(find.text('AI service')).dx,
          tester.getTopLeft(find.text('Playback Settings')).dx,
        );
      });

      testWidgets('设置页不提供账号、会员或检查更新入口', (tester) async {
        await tester.pumpWidget(
          createTestScreen(const SettingsScreen(), overrides: buildOverrides()),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Open Source Project'), 200);
        await tester.pumpAndSettle();

        expect(find.text('Check for Updates'), findsNothing);
        expect(find.text('Account'), findsNothing);
      });

      test('设置页 SVG 图标统一使用 24x24 viewBox', () {
        for (final asset in settingsSvgAssets) {
          final content = File(asset).readAsStringSync();
          final svgTag = RegExp(
            r'<svg\b[^>]*>',
            dotAll: true,
          ).firstMatch(content)?.group(0);

          expect(svgTag, isNotNull, reason: asset);
          expect(svgTag, contains('viewBox="0 0 24 24"'), reason: asset);
          expect(svgTag, contains('width="24"'), reason: asset);
          expect(svgTag, contains('height="24"'), reason: asset);
          expect(
            RegExp(r'\sviewBox=').allMatches(svgTag!).length,
            1,
            reason: asset,
          );
          expect(
            RegExp(r'\swidth=').allMatches(svgTag).length,
            1,
            reason: asset,
          );
          expect(
            RegExp(r'\sheight=').allMatches(svgTag).length,
            1,
            reason: asset,
          );
          expect(content, isNot(contains('<style')), reason: asset);
        }
      });

      test('设置页满框 SVG 图标声明资源级视觉缩放', () {
        const visuallyScaledAssets = {
          'assets/icon/diskette.svg',
          'assets/icon/trash-bin.svg',
          'assets/icon/refresh.svg',
          'assets/icon/lock.svg',
          'assets/icon/group.svg',
          'assets/icon/play-pause.svg',
        };

        for (final asset in visuallyScaledAssets) {
          final content = File(asset).readAsStringSync();
          expect(
            content,
            contains('data-settings-visual-scale='),
            reason: asset,
          );
          expect(content, contains('translate(12 12) scale('), reason: asset);
        }
      });

      testWidgets('显示主题设置项', (tester) async {
        await tester.pumpWidget(
          createTestScreen(const SettingsScreen(), overrides: buildOverrides()),
        );
        await tester.pumpAndSettle();

        expect(find.text('Theme'), findsOneWidget);
        // 默认 system 模式（主题和语言都显示"Follow System"）
        expect(find.text('Follow System'), findsAtLeast(1));
      });

      testWidgets('显示语言设置项', (tester) async {
        await tester.pumpWidget(
          createTestScreen(const SettingsScreen(), overrides: buildOverrides()),
        );
        await tester.pumpAndSettle();

        expect(find.text('App Language'), findsOneWidget);
        // 默认跟随系统
        expect(find.text('Follow System'), findsAtLeast(1));
      });

      testWidgets('普通设置项使用 SVG 图标替代 emoji', (tester) async {
        await tester.pumpWidget(
          createTestScreen(
            const SettingsScreen(),
            overrides: buildOverrides(
              showDeveloperOptions: false,
              showOfflineAsrSection: true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(findSvgAsset('assets/icon/artist-palette.svg'), findsOneWidget);
        expect(findSvgAsset('assets/icon/locale.svg'), findsOneWidget);
        expect(findSvgAsset('assets/icon/speak.svg'), findsOneWidget);
        expect(findSvgAsset('assets/icon/bell.svg'), findsOneWidget);
        expect(findSvgAsset('assets/icon/book-shelf.svg'), findsOneWidget);
        expect(findSvgAsset('assets/icon/microphone.svg'), findsOneWidget);
        expect(findSvgAsset('assets/icon/speaker.svg'), findsOneWidget);
        expect(findSvgAsset('assets/icon/play-pause.svg'), findsOneWidget);
        expect(findSvgAsset('assets/icon/locale-1.svg'), findsOneWidget);

        await tester.scrollUntilVisible(find.text('About'), 200);
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(find.text('Backup & Restore'), 200);
        await tester.pumpAndSettle();
        expect(findSvgAsset('assets/icon/diskette.svg'), findsOneWidget);
        expect(findSvgAsset('assets/icon/trash-bin.svg'), findsOneWidget);

        for (final emoji in [
          '👤',
          '💎',
          '🎨',
          '🌐',
          '🗣️',
          '🔔',
          '📚',
          '🎙️',
          '🔊',
          '▶️',
          '📖',
          '💾',
          '🗑️',
          '🔄',
          '📜',
          '🔒',
          '✉️',
          '👥',
        ]) {
          expect(find.text(emoji), findsNothing);
        }
      });

      testWidgets('设置页普通图标保留 leading 占位并收紧内部绘制尺寸', (tester) async {
        await tester.pumpWidget(
          createTestScreen(
            const SettingsScreen(),
            overrides: buildOverrides(showDeveloperOptions: false),
          ),
        );
        await tester.pumpAndSettle();

        final paletteIcon = tester.widget<SvgPicture>(
          findSvgAsset('assets/icon/artist-palette.svg'),
        );
        expect(paletteIcon.width, 26);
        expect(paletteIcon.height, 26);
        expect(
          tester.getSize(
            find
                .ancestor(
                  of: findSvgAsset('assets/icon/artist-palette.svg'),
                  matching: find.byType(SizedBox),
                )
                .first,
          ),
          const Size(32, 32),
        );

        await tester.scrollUntilVisible(find.text('Open Source Project'), 200);
        await tester.pumpAndSettle();

        final githubIcons = tester.widgetList<FaIcon>(find.byType(FaIcon));
        expect(githubIcons, hasLength(1));
        expect(githubIcons.single.size, 20);
      });

      testWidgets('深色主题下单色 SVG 使用高对比主题前景色', (tester) async {
        await tester.pumpWidget(
          createTestScreen(
            Theme(data: AppTheme.dark(), child: const SettingsScreen()),
            overrides: buildOverrides(
              showDeveloperOptions: false,
              showOfflineAsrSection: true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final expectedColor = AppTheme.dark().colorScheme.onSurfaceVariant;
        final paletteIcon = tester.widget<SvgPicture>(
          findSvgAsset('assets/icon/artist-palette.svg'),
        );
        expect(paletteIcon.colorFilter, isNull);

        const visibleAssets = [
          'assets/icon/speak.svg',
          'assets/icon/microphone.svg',
          'assets/icon/play-pause.svg',
          'assets/icon/trash-bin.svg',
        ];

        for (final asset in visibleAssets) {
          await tester.scrollUntilVisible(findSvgAsset(asset), 200);
          await tester.pumpAndSettle();
          final icon = tester.widget<SvgPicture>(findSvgAsset(asset));
          expect(
            icon.colorFilter,
            ColorFilter.mode(expectedColor, BlendMode.srcIn),
            reason: asset,
          );
        }
      });

      testWidgets('显示关于信息区域', (tester) async {
        await tester.pumpWidget(
          createTestScreen(const SettingsScreen(), overrides: buildOverrides()),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Open Source Project'), 200);
        await tester.pumpAndSettle();

        expect(find.text('About'), findsOneWidget);
        expect(find.text('Terms of Service'), findsNothing);
        expect(find.text('Privacy Policy'), findsNothing);
        expect(find.text('FAQ'), findsNothing);
        expect(find.text('Write Feedback'), findsNothing);
        expect(find.text('Join Community'), findsNothing);
        expect(find.text('Open Source Project'), findsOneWidget);
        expect(find.text('github.com/iron6909/loop-back'), findsNothing);
        // 版本标签在页面底部，需要滚动到可见
        await tester.scrollUntilVisible(find.textContaining('Version'), 200);
        await tester.pumpAndSettle();
        expect(find.text('Version 1.0.0 (Debug)'), findsOneWidget);
      });

      testWidgets('显示外观标题', (tester) async {
        await tester.pumpWidget(
          createTestScreen(const SettingsScreen(), overrides: buildOverrides()),
        );
        await tester.pumpAndSettle();

        expect(find.text('Appearance'), findsOneWidget);
      });

      testWidgets('Speech Recognition 入口仅在开关启用时显示', (tester) async {
        await tester.pumpWidget(
          createTestScreen(
            const SettingsScreen(),
            overrides: buildOverrides(showOfflineAsrSection: true),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Learning'), findsOneWidget);
        expect(find.text('Speech Recognition'), findsOneWidget);
      });

      testWidgets('学习分组顺序：AI 服务在语音识别上方，播放设置在显示设置下方', (tester) async {
        await tester.pumpWidget(
          createTestScreen(
            const SettingsScreen(),
            overrides: buildOverrides(showOfflineAsrSection: true),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('AI service'));
        await tester.pumpAndSettle();

        final aiY = tester.getTopLeft(find.text('AI service')).dy;
        final asrY = tester.getTopLeft(find.text('Speech Recognition')).dy;
        final displayY = tester.getTopLeft(find.text('Display Settings')).dy;
        final playbackY = tester.getTopLeft(find.text('Playback Settings')).dy;

        expect(aiY, lessThan(asrY));
        expect(playbackY, greaterThan(displayY));
        // 播放设置紧随显示设置之后，且位于 AI 服务上方
        expect(playbackY, lessThan(aiY));
      });

      testWidgets('语音合成入口显示当前 LoopBack 引擎，不显示口音', (tester) async {
        await tester.pumpWidget(
          createTestScreen(const SettingsScreen(), overrides: buildOverrides()),
        );
        await tester.pumpAndSettle();

        expect(find.text('Text-to-Speech'), findsOneWidget);
        expect(find.text('Kokoro'), findsOneWidget);
        expect(find.text('American'), findsNothing);
      });

      testWidgets('语音合成入口显示 LoopBack 引擎', (tester) async {
        await tester.pumpWidget(
          createTestScreen(
            const SettingsScreen(),
            overrides: buildOverrides(
              ttsSettings: const TtsSettings(engine: TtsEngineKind.kokoro),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Text-to-Speech'), findsOneWidget);
        expect(find.text('Kokoro'), findsOneWidget);
      });

      testWidgets('开发者选项关闭时不显示开发者分组', (tester) async {
        await tester.pumpWidget(
          createTestScreen(
            const SettingsScreen(),
            overrides: buildOverrides(showDeveloperOptions: false),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Developer'), findsNothing);
        expect(find.text('Time Machine'), findsNothing);
      });

      testWidgets('开发者区域仅保留选定工具，已删除功能不再出现', (tester) async {
        await tester.pumpWidget(
          createTestScreen(const SettingsScreen(), overrides: buildOverrides()),
        );
        await tester.pumpAndSettle();

        final titles = <String>{};
        // 遍历至开发者区域末尾，避免未构建的离屏入口造成误判。
        for (var step = 0; step < 30; step++) {
          for (final tile in tester.widgetList<ListTile>(
            find.byType(ListTile),
          )) {
            if (tile.title case Text(:final data?)) titles.add(data);
          }
          if (titles.contains('内部存储')) break;
          await tester.drag(find.byType(ListView).first, const Offset(0, -300));
          await tester.pumpAndSettle();
        }

        expect(
          titles,
          containsAll([
            'Time Machine',
            '日志',
            'Reset New User Guide',
            'Demo Mode',
            '词典查询',
            '偏好设置',
            '内部存储',
          ]),
        );
        expect(
          titles.intersection({
            'Analytics',
            '版本号覆盖',
            'ASR 引擎测试',
            '字幕自动校准',
            '订阅调试',
          }),
          isEmpty,
        );
      });

      testWidgets('开发者选项开启且未设置时时显示系统时间文案', (tester) async {
        await tester.pumpWidget(
          createTestScreen(const SettingsScreen(), overrides: buildOverrides()),
        );
        await tester.pumpAndSettle();

        // 滚动到开发者区域
        await tester.scrollUntilVisible(find.text('Time Machine'), 200);
        await tester.pumpAndSettle();

        expect(find.text('Developer'), findsOneWidget);
        expect(find.text('Time Machine'), findsOneWidget);
        expect(find.text('Use system time'), findsOneWidget);
      });

      testWidgets('开发者选项开启且已设置时时显示当前调试时间', (tester) async {
        await tester.pumpWidget(
          createTestScreen(
            const SettingsScreen(),
            overrides: buildOverrides(
              settings: AppSettingsState(
                timeMachineDateTime: DateTime(2026, 3, 11, 22, 15),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 滚动到开发者区域
        await tester.scrollUntilVisible(find.text('Time Machine'), 200);
        await tester.pumpAndSettle();

        // 调试时间显示在 Time Machine 对话框中，先点击打开
        await tester.tap(find.text('Time Machine'));
        await tester.pumpAndSettle();

        expect(find.textContaining('Debug time:'), findsOneWidget);
      });
    });

    group('交互', () {
      testWidgets('点击主题设置弹出选择对话框', (tester) async {
        await tester.pumpWidget(
          createTestScreen(const SettingsScreen(), overrides: buildOverrides()),
        );
        await tester.pumpAndSettle();

        // 点击主题设置项
        await tester.tap(find.text('Theme'));
        await tester.pumpAndSettle();

        // 应弹出对话框，显示三个选项
        expect(find.text('Light Mode'), findsOneWidget);
        expect(find.text('Dark Mode'), findsOneWidget);
        // 对话框标题 + 列表中的 Follow System
        expect(find.text('Follow System'), findsAtLeast(1));
        expect(find.byIcon(Icons.brightness_auto_rounded), findsOneWidget);
        expect(find.byIcon(Icons.light_mode_rounded), findsOneWidget);
        expect(find.byIcon(Icons.dark_mode_rounded), findsOneWidget);
        expect(find.text('⚙️'), findsNothing);
        expect(find.text('☀️'), findsNothing);
        expect(find.text('🌛'), findsNothing);
      });

      testWidgets('选择 Dark 主题后状态更新', (tester) async {
        await tester.pumpWidget(
          createTestScreen(const SettingsScreen(), overrides: buildOverrides()),
        );
        await tester.pumpAndSettle();

        // 打开主题选择对话框
        await tester.tap(find.text('Theme'));
        await tester.pumpAndSettle();

        // 选择 Dark Mode
        await tester.tap(find.text('Dark Mode'));
        await tester.pumpAndSettle();

        // 对话框关闭后，应显示 Dark Mode
        expect(find.text('Dark Mode'), findsOneWidget);
      });

      testWidgets('点击语言设置弹出选择对话框', (tester) async {
        await tester.pumpWidget(
          createTestScreen(const SettingsScreen(), overrides: buildOverrides()),
        );
        await tester.pumpAndSettle();

        // 点击语言设置项
        await tester.tap(find.text('App Language'));
        await tester.pumpAndSettle();

        // 应弹出对话框，显示三个选项
        expect(find.text('Follow System'), findsAtLeast(1));
        expect(find.text('English'), findsAtLeast(1));
        expect(find.text('简体中文'), findsAtLeast(1));
      });

      testWidgets('点击时光机弹出设置对话框', (tester) async {
        await tester.pumpWidget(
          createTestScreen(const SettingsScreen(), overrides: buildOverrides()),
        );
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(find.text('Time Machine'), 200);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Time Machine'));
        await tester.pumpAndSettle();

        expect(find.text('Select date'), findsOneWidget);
        expect(find.text('Select time'), findsOneWidget);
        expect(find.text('Save'), findsOneWidget);
      });

      testWidgets('点击恢复系统时间并保存后清除时光机', (tester) async {
        await tester.pumpWidget(
          createTestScreen(
            const SettingsScreen(),
            overrides: buildOverrides(
              settings: AppSettingsState(
                timeMachineDateTime: DateTime(2026, 3, 11, 22, 15),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(find.text('Time Machine'), 200);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Time Machine'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Use system time'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        expect(find.text('Use system time'), findsOneWidget);
        expect(find.text('Debug time: 2026-03-11 22:15'), findsNothing);
      });
    });
  });
}

/// 测试用 DeveloperOptions Notifier，固定返回指定值。
class _TestDeveloperOptions extends DeveloperOptions {
  final bool _value;
  _TestDeveloperOptions(this._value);

  @override
  bool build() => _value;

  @override
  Future<void> setEnabled(bool value) async {
    state = value;
  }
}
