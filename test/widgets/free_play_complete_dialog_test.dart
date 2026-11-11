import 'package:loop_back/l10n/app_localizations.dart';
import 'package:loop_back/widgets/dialogs/free_play_complete_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets('完成操作按钮按内容宽度显示且英文标签不折行', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      createTestApp(
        Builder(
          builder: (context) => FreePlayCompleteDialog(
            onResult: (_) {},
            title: 'Practice complete',
          ),
        ),
        locale: const Locale('en'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final l10n = AppLocalizations.of(
      tester.element(find.byType(FreePlayCompleteDialog)),
    )!;
    final replayLabel = tester.widget<Text>(find.text(l10n.listenAgain));
    final doneLabel = tester.widget<Text>(find.text(l10n.done));

    expect(replayLabel.maxLines, 1);
    expect(replayLabel.softWrap, isFalse);
    expect(doneLabel.maxLines, 1);
    expect(doneLabel.softWrap, isFalse);

    final replayButton = tester.getSize(
      find.widgetWithText(OutlinedButton, l10n.listenAgain),
    );
    final doneButton = tester.getSize(
      find.widgetWithText(FilledButton, l10n.done),
    );
    expect(replayButton.width, greaterThan(doneButton.width));
    final animation = tester.widget<LottieBuilder>(
      find.byKey(const Key('completion-dialog-done-check')),
    );
    expect(animation.repeat, isTrue);
    expect(animation.animate, isTrue);
    expect(
      tester.getSize(find.byKey(const Key('completion-dialog-done-check'))),
      const Size(160, 160),
    );
    expect(tester.takeException(), isNull);
  });
}
