import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/l10n/app_localizations.dart';
import 'package:loop_back/widgets/common/playback_controls.dart';
import 'package:loop_back/widgets/common/practice_playback_footer.dart';
import 'package:loop_back/widgets/practice/practice_play_count_label.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets('手动模式 status label 与自动模式使用相同文字样式', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        Builder(
          builder: (context) {
            final l10n = AppLocalizations.of(context)!;
            final theme = Theme.of(context);
            return Column(
              children: [
                PracticePlayCountLabel(
                  isManualMode: false,
                  playCountText: formatPracticePlayCount(
                    l10n,
                    currentCount: 1,
                    totalCount: 2,
                  ),
                  statusSuffixText: '1.0x',
                  l10n: l10n,
                  theme: theme,
                ),
                PracticePlayCountLabel(
                  isManualMode: true,
                  playCountText: formatPracticePlayCount(
                    l10n,
                    currentCount: 1,
                    totalCount: 2,
                  ),
                  statusSuffixText: '1.0x',
                  l10n: l10n,
                  theme: theme,
                ),
              ],
            );
          },
        ),
        locale: const Locale('zh'),
      ),
    );
    await tester.pump();

    final autoLabel = tester.widget<Text>(find.text('自动 · 第 1/2 遍 · 1.0x'));
    final manualLabel = tester.widget<Text>(find.text('手动 · 第 1/2 遍 · 1.0x'));

    expect(manualLabel.style, autoLabel.style);
  });

  testWidgets('手动模式单次循环也显示遍数', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        Builder(
          builder: (context) => PracticePlayCountLabel(
            isManualMode: true,
            playCountText: formatPracticePlayCount(
              AppLocalizations.of(context)!,
              currentCount: 1,
              totalCount: 1,
            ),
            l10n: AppLocalizations.of(context)!,
            theme: Theme.of(context),
          ),
        ),
        locale: const Locale('zh'),
      ),
    );

    expect(find.text('手动 · 第 1/1 遍'), findsOneWidget);
  });

  testWidgets('播放控制按钮提供 Material 悬浮按压和聚焦反馈', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        const Center(
          child: PlaybackControls(
            canGoPrev: true,
            isLast: false,
            centerIcon: Icons.play_arrow_rounded,
            onPrevious: _noop,
            onNext: _noop,
            onCenter: _noop,
          ),
        ),
      ),
    );
    await tester.pump();

    IconButton buttonFor(IconData icon) => tester.widget<IconButton>(
      find.ancestor(of: find.byIcon(icon), matching: find.byType(IconButton)),
    );

    final previousButton = buttonFor(Icons.skip_previous_rounded);
    final centerButton = buttonFor(Icons.play_arrow_rounded);
    final nextButton = buttonFor(Icons.skip_next_rounded);

    for (final button in [previousButton, centerButton, nextButton]) {
      expect(
        button.style?.overlayColor?.resolve({WidgetState.hovered}),
        isNotNull,
      );
      expect(
        button.style?.overlayColor?.resolve({WidgetState.pressed}),
        isNotNull,
      );
      expect(
        button.style?.overlayColor?.resolve({WidgetState.focused}),
        isNotNull,
      );
    }

    expect(centerButton, isA<IconButton>());
    expect(
      centerButton.style?.fixedSize?.resolve({}),
      const Size.square(PlaybackControls.controlButtonSize),
    );
  });

  testWidgets('禁用的上一句按钮不响应点击', (tester) async {
    var previousCalls = 0;
    await tester.pumpWidget(
      createTestApp(
        Center(
          child: PlaybackControls(
            canGoPrev: false,
            isLast: false,
            centerIcon: Icons.play_arrow_rounded,
            onPrevious: () => previousCalls += 1,
            onNext: _noop,
            onCenter: _noop,
          ),
        ),
      ),
    );
    await tester.pump();

    final previousButton = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.skip_previous_rounded),
        matching: find.byType(IconButton),
      ),
    );
    expect(previousButton.onPressed, isNull);

    await tester.tap(find.byIcon(Icons.skip_previous_rounded));
    await tester.pump();
    expect(previousCalls, 0);
  });

  testWidgets('移动端学习页底部控制区完整避让系统安全区', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);

    await tester.pumpWidget(
      createTestApp(
        Builder(
          builder: (context) {
            final l10n = AppLocalizations.of(context)!;
            return Column(
              children: [
                const Spacer(),
                PracticePlaybackFooter(
                  canGoPrev: true,
                  isLast: false,
                  centerIcon: Icons.play_arrow_rounded,
                  onPrevious: () {},
                  onNext: () {},
                  onCenter: () {},
                  isManualMode: false,
                  playCountText: formatPracticePlayCount(
                    l10n,
                    currentCount: 1,
                    totalCount: 1,
                  ),
                  statusSuffixText: '1.0x',
                  l10n: l10n,
                  theme: Theme.of(context),
                ),
              ],
            );
          },
        ),
        locale: const Locale('zh'),
      ),
    );
    await tester.pump();

    final labelBottom = tester
        .getRect(find.byKey(kPracticePlaybackFooterLabelKey))
        .bottom;
    final screenBottom =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;

    // footer 的播放按钮和 label 统一避让底部系统区域，不再只给 label 留半个 inset。
    expect(screenBottom - labelBottom, closeTo(34, 0.1));
  });

  testWidgets('支持替换右侧下一句控件', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        Builder(
          builder: (context) => PracticePlaybackFooter(
            canGoPrev: true,
            isLast: false,
            centerIcon: Icons.play_arrow_rounded,
            onPrevious: () {},
            onNext: () {},
            onCenter: () {},
            nextControl: const Text('继续'),
            isManualMode: false,
            playCountText: '1/1',
            l10n: AppLocalizations.of(context)!,
            theme: Theme.of(context),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('继续'), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_rounded), findsNothing);
  });

  testWidgets('自定义右侧控件宽度变化时上一句和播放按钮间距保持不变', (tester) async {
    Widget buildControls({Widget? nextControl}) {
      return createTestApp(
        Center(
          child: PlaybackControls(
            canGoPrev: true,
            isLast: false,
            centerIcon: Icons.play_arrow_rounded,
            onPrevious: () {},
            onNext: () {},
            onCenter: () {},
            nextControl: nextControl == null
                ? null
                : SizedBox(width: 128, height: 48, child: nextControl),
            nextControlWidth: nextControl == null ? null : 128,
          ),
        ),
      );
    }

    double gapBetweenPreviousAndPlay() {
      final previousCenter = tester
          .getCenter(find.byType(PlaybackNavButton).first)
          .dx;
      final playCenter = tester
          .getCenter(find.byIcon(Icons.play_arrow_rounded))
          .dx;
      return playCenter - previousCenter;
    }

    await tester.pumpWidget(buildControls());
    await tester.pump();
    final gapDefault = gapBetweenPreviousAndPlay();

    // 自定义控件比默认 56x56 的下一句按钮窄（模拟旧版 48x48 图标继续按钮）。
    await tester.pumpWidget(
      buildControls(
        nextControl: IconButton.filled(
          onPressed: () {},
          icon: const Icon(Icons.arrow_forward_rounded),
          style: IconButton.styleFrom(fixedSize: const Size.square(48)),
        ),
      ),
    );
    await tester.pump();
    expect(gapBetweenPreviousAndPlay(), gapDefault);

    // 自定义控件因为带文字标签而明显更宽（模拟精听页"继续"按钮）。
    await tester.pumpWidget(
      buildControls(
        nextControl: FilledButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.arrow_forward_rounded),
          label: const Text('继续'),
        ),
      ),
    );
    await tester.pump();
    // 上一句和播放按钮之间的间距只由左侧内容决定，不随右侧控件宽度变化——
    // 这是修复「Stack 贴边导致按钮跳动」这个 bug 的核心不变量。
    expect(gapBetweenPreviousAndPlay(), gapDefault);

    // 播放按钮和继续按钮之间的间距必须等于「半个播放按钮 + 固定间距 + 半个继续按钮
    // 的实际宽度」，不能因为 nextControl 被错误地撑满剩余空间而变成一大截
    // 空白（这正是把 FittedBox 包一层 Center/Align 会导致的 bug）。
    const nextButtonWidth = 128.0;
    final playCenter = tester
        .getCenter(find.byIcon(Icons.play_arrow_rounded))
        .dx;
    final nextCenter = tester.getCenter(find.byType(FilledButton)).dx;
    expect(
      nextCenter - playCenter,
      closeTo(
        PlaybackControls.controlButtonSize / 2 +
            PlaybackControls.controlButtonGap +
            nextButtonWidth / 2,
        0.5,
      ),
    );
  });

  testWidgets('宽屏下播放按钮始终固定在正中间，不随继续按钮宽度挪动', (tester) async {
    tester.view.physicalSize = const Size(1236, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Widget buildControls({Widget? nextControl, double? nextControlWidth}) {
      return createTestApp(
        Align(
          alignment: Alignment.topCenter,
          child: PlaybackControls(
            canGoPrev: true,
            isLast: false,
            centerIcon: Icons.play_arrow_rounded,
            onPrevious: () {},
            onNext: () {},
            onCenter: () {},
            nextControl: nextControl,
            nextControlWidth: nextControlWidth,
          ),
        ),
      );
    }

    final screenWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;

    // 没有继续按钮时，播放按钮应该精确位于屏幕正中间。
    await tester.pumpWidget(buildControls());
    await tester.pump();
    final playCenterDefault = tester
        .getCenter(find.byIcon(Icons.play_arrow_rounded))
        .dx;
    expect(playCenterDefault, closeTo(screenWidth / 2, 0.5));

    // 出现一个很宽的继续按钮后，播放按钮的位置必须原地不动——
    // 这是本次修复的核心诉求：主按钮固定在中间，不随右侧宽度变化而挪动。
    await tester.pumpWidget(
      buildControls(
        nextControlWidth: 128,
        nextControl: SizedBox(
          width: 128,
          height: 48,
          child: FilledButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.arrow_forward_rounded),
            label: const Text('Continue to the next sentence'),
          ),
        ),
      ),
    );
    await tester.pump();
    final playCenterWithWideNext = tester
        .getCenter(find.byIcon(Icons.play_arrow_rounded))
        .dx;
    expect(playCenterWithWideNext, closeTo(playCenterDefault, 0.5));

    expect(
      tester.getSize(
        find.widgetWithText(FilledButton, 'Continue to the next sentence'),
      ),
      const Size(128, 48),
    );
  });

  testWidgets('窄屏下带文字的继续按钮不会撑爆 Row', (tester) async {
    tester.view.physicalSize = const Size(352, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      createTestApp(
        PlaybackControls(
          canGoPrev: true,
          isLast: false,
          centerIcon: Icons.play_arrow_rounded,
          onPrevious: () {},
          onNext: () {},
          onCenter: () {},
          nextControl: FilledButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.arrow_forward_rounded),
            label: const Text('Continue'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

void _noop() {}
