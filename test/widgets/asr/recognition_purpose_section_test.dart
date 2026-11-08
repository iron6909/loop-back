/// 设置页的用途识别选择：三用途独立展示、系统识别可用范围、变更前的确认与拒绝。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_loop/l10n/app_localizations.dart';
import 'package:echo_loop/models/recognition_selection.dart';
import 'package:echo_loop/providers/recognition_settings_provider.dart';
import 'package:echo_loop/providers/speech_capability_provider.dart';
import 'package:echo_loop/services/speech/practice_online_transcriber.dart';
import 'package:echo_loop/theme/app_theme.dart';
import 'package:echo_loop/widgets/asr/recognition_purpose_section.dart';

const _initial = RecognitionSettings(
  subtitle: RecognitionSelection.local('whisper-small-en-int8'),
  shadowing: RecognitionSelection.local('whisper-base-en-int8'),
  retell: RecognitionSelection.local('whisper-tiny-en-int8'),
);

class _ChangeCall {
  _ChangeCall(this.purpose, this.selection, this.cancelInFlight);

  final RecognitionPurpose purpose;
  final RecognitionSelection selection;
  final bool cancelInFlight;
}

/// 记录变更请求并可按脚本返回「需要确认」的用途选择 Notifier。
class _RecordingRecognitionSettings extends RecognitionSettingsNotifier {
  _RecordingRecognitionSettings(this._pendingTasks, {this.confirmOnce = false});

  final List<RecognitionInFlightTask> _pendingTasks;

  /// 只在首次变更时要求确认，用于验证「接受后二次应用」。
  final bool confirmOnce;
  final List<_ChangeCall> calls = [];
  final List<RecognitionInFlightTask> cancelledTasks = [];

  @override
  RecognitionSettings build() => _initial;

  @override
  Future<RecognitionChangeResult> change({
    required RecognitionPurpose purpose,
    required RecognitionSelection selection,
    bool cancelInFlight = false,
  }) async {
    calls.add(_ChangeCall(purpose, selection, cancelInFlight));
    if (_pendingTasks.isNotEmpty &&
        !cancelInFlight &&
        (!confirmOnce || calls.length == 1)) {
      return RecognitionChangeResult.needsConfirmation(_pendingTasks);
    }
    for (final task in _pendingTasks) {
      await task.onCancel();
      cancelledTasks.add(task);
    }
    state = state.withPurpose(purpose, selection);
    return const RecognitionChangeResult.applied();
  }
}

Widget _buildHarness(
  _RecordingRecognitionSettings notifier, {
  required bool systemSupported,
  bool onlineAvailable = false,
  bool? retellOnlineAvailable,
  PracticeOnlineAccessDenial onlineBlockReason =
      PracticeOnlineAccessDenial.missingConfiguration,
}) {
  return ProviderScope(
    overrides: [
      recognitionSettingsProvider.overrideWith(() => notifier),
      systemRecognitionPlatformProvider.overrideWithValue(systemSupported),
      onlinePracticeAvailabilityProvider(
        RecognitionPurpose.shadowing,
      ).overrideWith((ref) async => onlineAvailable),
      onlinePracticeAvailabilityProvider(
        RecognitionPurpose.retell,
      ).overrideWith((ref) async => retellOnlineAvailable ?? onlineAvailable),
      // 在线不可选时界面仍展示该方式并说明原因，故需要明确的阻断原因。
      for (final purpose in RecognitionPurpose.values)
        onlineModeBlockReasonProvider(purpose).overrideWith(
          (ref) => switch (purpose) {
            RecognitionPurpose.shadowing =>
              onlineAvailable ? null : onlineBlockReason,
            RecognitionPurpose.retell =>
              (retellOnlineAvailable ?? onlineAvailable)
                  ? null
                  : onlineBlockReason,
            RecognitionPurpose.subtitle => onlineBlockReason,
          },
        ),
    ],
    child: MaterialApp(
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light(),
      home: const Scaffold(
        body: SingleChildScrollView(child: RecognitionPurposeSection()),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('三个用途各自展示方式与自己的模型，互不借用', (tester) async {
    final notifier = _RecordingRecognitionSettings(const []);
    await tester.pumpWidget(_buildHarness(notifier, systemSupported: true));
    await tester.pumpAndSettle();

    expect(find.text('Subtitles'), findsOneWidget);
    expect(find.text('Shadowing'), findsOneWidget);
    expect(find.text('Retelling'), findsOneWidget);
    expect(find.text('On-device · Whisper Small (English)'), findsOneWidget);
    expect(find.text('On-device · Whisper Base (English)'), findsOneWidget);
    expect(find.text('On-device · Whisper Tiny (English)'), findsOneWidget);
  });

  testWidgets('字幕用途只选本机档位，方式在管理字幕弹窗里并列选择', (tester) async {
    final notifier = _RecordingRecognitionSettings(const []);
    await tester.pumpWidget(_buildHarness(notifier, systemSupported: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Subtitles'));
    await tester.pumpAndSettle();

    // 字幕不提供系统识别，也不在用途面板选方式（本地/在线为弹窗里的并列入口）。
    expect(find.text('System speech'), findsNothing);
    expect(find.text('Online speech'), findsNothing);
    expect(find.text('Whisper Tiny (English)'), findsOneWidget);
    // 在线模型去哪里配：面板里直接说明。
    expect(
      find.textContaining('Configure the online model and key under Online speech'),
      findsOneWidget,
    );
  });

  testWidgets('支持的平台上跟读可选系统识别，保存的是跟读自己的选择', (tester) async {
    final notifier = _RecordingRecognitionSettings(const []);
    await tester.pumpWidget(_buildHarness(notifier, systemSupported: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Shadowing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('System speech'));
    await tester.pumpAndSettle();

    expect(notifier.calls, hasLength(1));
    expect(notifier.calls.single.purpose, RecognitionPurpose.shadowing);
    expect(notifier.calls.single.selection.mode, RecognitionMode.system);
    expect(
      notifier.calls.single.selection.localModelId,
      'whisper-base-en-int8',
      reason: '切到系统识别后仍保留本机档位，切回时不用重选',
    );
    // 摘要跟随共享状态更新，其它用途不受影响。
    expect(find.text('System speech'), findsNWidgets(2));
    expect(find.text('On-device · Whisper Small (English)'), findsOneWidget);
    expect(find.text('On-device · Whisper Tiny (English)'), findsOneWidget);
  });

  testWidgets('不支持的平台只提供本机方式', (tester) async {
    final notifier = _RecordingRecognitionSettings(const []);
    await tester.pumpWidget(_buildHarness(notifier, systemSupported: false));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Shadowing'));
    await tester.pumpAndSettle();

    expect(find.text('System speech'), findsNothing);
    expect(find.text('Whisper Base (English)'), findsOneWidget);
  });

  testWidgets('有受影响的在途任务时先确认，拒绝则保留配置与任务', (tester) async {
    final cancelled = <RecognitionInFlightTask>[];
    late final RecognitionInFlightTask task;
    task = RecognitionInFlightTask(
      purpose: RecognitionPurpose.retell,
      label: 'retell:a1:0',
      onCancel: () async => cancelled.add(task),
    );
    final notifier = _RecordingRecognitionSettings([task]);
    await tester.pumpWidget(_buildHarness(notifier, systemSupported: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Retelling'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('System speech'));
    await tester.pumpAndSettle();

    expect(find.text('Change recognition settings?'), findsOneWidget);
    expect(
      find.text(
        'Running recognition tasks affected: 1. Continuing cancels them and '
        'discards unfinished results.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(notifier.calls, hasLength(1));
    expect(cancelled, isEmpty, reason: '拒绝时不取消在途任务');
    expect(find.text('On-device · Whisper Tiny (English)'), findsOneWidget);
  });

  testWidgets('接受确认后带取消标记重新应用并取消受影响任务', (tester) async {
    final cancelled = <RecognitionInFlightTask>[];
    late final RecognitionInFlightTask task;
    task = RecognitionInFlightTask(
      purpose: RecognitionPurpose.retell,
      label: 'retell:a1:0',
      onCancel: () async => cancelled.add(task),
    );
    final notifier = _RecordingRecognitionSettings([task], confirmOnce: true);
    await tester.pumpWidget(_buildHarness(notifier, systemSupported: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Retelling'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('System speech'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel tasks and change'));
    await tester.pumpAndSettle();

    expect(notifier.calls, hasLength(2));
    expect(notifier.calls.last.cancelInFlight, isTrue);
    expect(notifier.calls.last.purpose, RecognitionPurpose.retell);
    expect(notifier.calls.last.selection.mode, RecognitionMode.system);
    expect(cancelled, [task]);
    expect(find.text('System speech'), findsNWidgets(2));
    expect(find.text('On-device · Whisper Small (English)'), findsOneWidget);
  });

  testWidgets('具备 Key、告知与文本验证时跟读可选在线，保存为跟读自己的在线方式', (tester) async {
    final notifier = _RecordingRecognitionSettings(const []);
    await tester.pumpWidget(
      _buildHarness(notifier, systemSupported: true, onlineAvailable: true),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Shadowing'));
    await tester.pumpAndSettle();
    expect(find.text('Online speech'), findsOneWidget);

    await tester.tap(find.text('Online speech'));
    await tester.pumpAndSettle();

    expect(notifier.calls, hasLength(1));
    expect(notifier.calls.single.purpose, RecognitionPurpose.shadowing);
    expect(notifier.calls.single.selection.mode, RecognitionMode.online);
    expect(
      notifier.calls.single.selection.localModelId,
      'whisper-base-en-int8',
      reason: '切到在线后仍保留本机档位，切回时不用重选',
    );
  });

  testWidgets('复述通过自己的文本验证后可选在线，保存为复述自己的在线方式', (tester) async {
    final notifier = _RecordingRecognitionSettings(const []);
    await tester.pumpWidget(
      _buildHarness(notifier, systemSupported: true, onlineAvailable: true),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Retelling'));
    await tester.pumpAndSettle();
    expect(find.text('Online speech'), findsOneWidget);

    await tester.tap(find.text('Online speech'));
    await tester.pumpAndSettle();

    expect(notifier.calls, hasLength(1));
    expect(notifier.calls.single.purpose, RecognitionPurpose.retell);
    expect(notifier.calls.single.selection.mode, RecognitionMode.online);
  });

  testWidgets('跟读通过验证不等于复述可在线：复述的在线仍不可选', (tester) async {
    final notifier = _RecordingRecognitionSettings(const []);
    await tester.pumpWidget(
      _buildHarness(
        notifier,
        systemSupported: true,
        onlineAvailable: true,
        retellOnlineAvailable: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Retelling'));
    await tester.pumpAndSettle();

    // 复述的在线仍依赖自己的验证：列出但不可选。
    final onlineTile = tester.widget<RadioListTile<RecognitionMode>>(
      find.widgetWithText(RadioListTile<RecognitionMode>, 'Online speech'),
    );
    expect(onlineTile.enabled, isFalse);
    expect(onlineTile.value, RecognitionMode.online);
    expect(find.text('System speech'), findsOneWidget);
  });

  testWidgets('在线未配置时仍列出该方式，并说明缺配置而不是隐藏', (tester) async {
    final notifier = _RecordingRecognitionSettings(const []);
    await tester.pumpWidget(
      _buildHarness(
        notifier,
        systemSupported: true,
        onlineBlockReason: PracticeOnlineAccessDenial.missingConfiguration,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Shadowing'));
    await tester.pumpAndSettle();

    // 方式仍可见，但不可选，并直接说明还缺哪一步。
    expect(find.text('Online speech'), findsOneWidget);
    expect(
      find.text(
        'Set the service address and key under Online speech below first',
      ),
      findsOneWidget,
    );
    final onlineTile = tester.widget<RadioListTile<RecognitionMode>>(
      find.widgetWithText(RadioListTile<RecognitionMode>, 'Online speech'),
    );
    expect(onlineTile.enabled, isFalse);
    expect(find.text('System speech'), findsOneWidget);
  });

  testWidgets('在线缺少上传告知时，提示直接指向「验证模型」按钮', (tester) async {
    final notifier = _RecordingRecognitionSettings(const []);
    await tester.pumpWidget(
      _buildHarness(
        notifier,
        systemSupported: true,
        onlineBlockReason: PracticeOnlineAccessDenial.uploadNoticeMissing,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Shadowing'));
    await tester.pumpAndSettle();

    // 告知在「验证模型」弹窗里完成，提示必须指向那个按钮，而不是一个不存在的入口。
    expect(
      find.text(
        'Tap Verify model under Online speech below; the first time explains the upload target and possible charges',
      ),
      findsOneWidget,
    );
  });

  testWidgets('在线可用时不再展示阻断原因', (tester) async {
    final notifier = _RecordingRecognitionSettings(const []);
    await tester.pumpWidget(
      _buildHarness(notifier, systemSupported: true, onlineAvailable: true),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Shadowing'));
    await tester.pumpAndSettle();

    expect(find.text('Online speech'), findsOneWidget);
    expect(
      find.text(
        'Set the service address and key under Online speech below first',
      ),
      findsNothing,
    );
  });
}
