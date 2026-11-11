import 'package:loop_back/l10n/app_localizations.dart';
import 'package:loop_back/theme/app_theme.dart';
import 'package:loop_back/widgets/listen_and_repeat/listen_and_repeat_settings_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildTestWidget() => ProviderScope(
    child: MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => showListenAndRepeatSettingsSheet(context: context),
            child: const Text('打开设置'),
          ),
        ),
      ),
    ),
  );

  testWidgets('小视口滚动内容后仍可通过固定关闭按钮关闭', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(buildTestWidget());
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -160),
    );
    await tester.pumpAndSettle();

    final closeButton = find.byKey(const Key('settings-sheet-close'));
    expect(closeButton, findsOneWidget);
    await tester.tap(closeButton);
    await tester.pumpAndSettle();
    expect(closeButton, findsNothing);
  });
}
