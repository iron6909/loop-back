/// 「上次导入的文件夹」记忆。
///
/// Android 的系统目录选择器（SAF `ACTION_OPEN_DOCUMENT_TREE`）不支持由应用指定初始
/// 位置，所以「下次从上次的文件夹继续」只能靠应用自己记住已持久授权的 tree URI，
/// 再按该 URI 重新列出子项。授权本身由原生侧 `takePersistableUriPermission` 持久化，
/// 这里只保存 URI 与显示名，不含任何文件内容。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/shared_preferences_provider.dart';

/// 记住的文件夹：显示名 + 已持久授权的 SAF tree URI。
class RememberedImportDirectory {
  const RememberedImportDirectory({required this.name, required this.uri});

  final String name;
  final String uri;
}

/// 上次成功导入的文件夹，只保留一条；失效时由调用方清空。
class LastImportDirectoryStore {
  LastImportDirectoryStore(this._prefs);

  static const nameKey = 'folder_import_last_directory_name';
  static const uriKey = 'folder_import_last_directory_uri';

  final SharedPreferences _prefs;

  RememberedImportDirectory? read() {
    final uri = _prefs.getString(uriKey);
    final name = _prefs.getString(nameKey);
    if (uri == null || uri.isEmpty || name == null || name.isEmpty) {
      return null;
    }
    return RememberedImportDirectory(name: name, uri: uri);
  }

  Future<void> save(RememberedImportDirectory directory) async {
    await _prefs.setString(uriKey, directory.uri);
    await _prefs.setString(nameKey, directory.name);
  }

  Future<void> clear() async {
    await _prefs.remove(uriKey);
    await _prefs.remove(nameKey);
  }
}

final lastImportDirectoryStoreProvider = Provider<LastImportDirectoryStore>(
  (ref) => LastImportDirectoryStore(ref.read(sharedPreferencesProvider)),
);
