import 'package:loop_back/models/dict_entry.dart';
import 'package:loop_back/models/dictionary/dictionary_lookup_result.dart';
import 'package:loop_back/services/dictionary/dictionary_source.dart';
import 'package:loop_back/services/dictionary/local_dictionary_source.dart';
import 'package:loop_back/services/dictionary_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockDictionaryService extends Mock implements DictionaryService {}

void main() {
  late MockDictionaryService service;
  late LocalDictionarySource source;

  setUp(() {
    service = MockDictionaryService();
    source = LocalDictionarySource(service);
  });

  const req = DictionaryLookupRequest(word: 'run');

  test('元数据', () {
    expect(source.id, 'local');
    expect(source.canBeDisabled, isFalse);
    expect(source.requiresNetwork, isFalse);
  });

  test('词典就绪且命中 → LocalDictResult', () async {
    when(() => service.isAvailable).thenReturn(true);
    when(
      () => service.lookup('run'),
    ).thenReturn(const DictEntry(word: 'run', phonetic: 'rʌn'));

    final result = await source.lookup(req);

    expect(result, isA<LocalDictResult>());
    expect((result! as LocalDictResult).entry.word, 'run');
  });

  test('词典就绪但未收录 → null', () async {
    when(() => service.isAvailable).thenReturn(true);
    when(() => service.lookup('run')).thenReturn(null);

    expect(await source.lookup(req), isNull);
  });

  test('词典未就绪 → null（视图层据下载状态处理，不查询）', () async {
    when(() => service.isAvailable).thenReturn(false);

    expect(await source.lookup(req), isNull);
    verifyNever(() => service.lookup(any()));
  });
}
