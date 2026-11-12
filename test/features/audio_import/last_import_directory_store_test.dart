/// 「上次导入的文件夹」记忆的读写与失效处理。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/features/audio_import/last_import_directory_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('上次导入的文件夹可保存、读出与清空', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LastImportDirectoryStore(
      await SharedPreferences.getInstance(),
    );

    expect(store.read(), isNull);
    await store.save(
      const RememberedImportDirectory(
        name: 'Lessons',
        uri: 'content://tree/lessons',
      ),
    );
    expect(store.read()?.name, 'Lessons');
    expect(store.read()?.uri, 'content://tree/lessons');

    await store.clear();
    expect(store.read(), isNull);
  });

  test('URI 与显示名只有一半时不当作有效记忆', () async {
    SharedPreferences.setMockInitialValues({
      LastImportDirectoryStore.uriKey: 'content://tree/lessons',
    });
    final store = LastImportDirectoryStore(
      await SharedPreferences.getInstance(),
    );
    expect(store.read(), isNull);
  });
}
