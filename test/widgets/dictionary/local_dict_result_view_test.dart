import 'package:loop_back/l10n/app_localizations.dart';
import 'package:loop_back/models/dict_entry.dart';
import 'package:loop_back/models/dictionary/dictionary_lookup_result.dart';
import 'package:loop_back/providers/dictionary/lookup_controller.dart';
import 'package:loop_back/services/dictionary_service.dart';
import 'package:loop_back/widgets/dictionary/local_dict_result_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockDictionaryService extends Mock implements DictionaryService {}

Widget _wrap(Widget child) => ProviderScope(
  child: MaterialApp(
    locale: const Locale('en'),
    supportedLocales: const [Locale('en'), Locale('zh')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  late DictionaryService old;
  late MockDictionaryService mock;

  setUp(() {
    mock = MockDictionaryService();
    when(() => mock.isAvailable).thenReturn(true);
    old = DictionaryService.replaceInstance(mock);
  });

  tearDown(() => DictionaryService.replaceInstance(old));

  testWidgets('已收录：渲染音标与释义', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const LocalDictResultView(
          word: 'run',
          state: LookupLoaded(
            LocalDictResult(
              DictEntry(
                word: 'run',
                phonetic: 'rʌn',
                translation: 'v. 跑',
                collins: 3,
                examTags: ['CET4'],
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('/rʌn/'), findsOneWidget);
    expect(find.text('跑'), findsOneWidget);
    expect(find.text('v.'), findsOneWidget);
    expect(find.text('CET4'), findsOneWidget);
    // 表面词形（run）与命中词一致：不显示原形回退提示
    expect(find.textContaining('base form'), findsNothing);
  });

  testWidgets('原形回退：表面词形与命中词不同时显示弱化提示', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const LocalDictResultView(
          word: 'running',
          state: LookupLoaded(
            LocalDictResult(
              DictEntry(word: 'run', phonetic: 'rʌn', translation: 'v. 跑'),
            ),
          ),
        ),
      ),
    );
    // 释义仍是原形 run 的内容
    expect(find.text('/rʌn/'), findsOneWidget);
    // 弱化提示告知展示的是原形 run 的查词结果
    expect(find.textContaining('run'), findsWidgets);
    expect(find.textContaining('base form'), findsOneWidget);
  });

  testWidgets('未收录：显示提示', (tester) async {
    await tester.pumpWidget(
      _wrap(const LocalDictResultView(word: 'xyz', state: LookupNotFound())),
    );
    expect(find.text('Word not found in dictionary'), findsOneWidget);
  });
}
