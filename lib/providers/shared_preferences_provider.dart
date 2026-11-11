/// SharedPreferences 实例 Provider。
///
/// 在 `main()` 加载 SP 之后通过 `ProviderScope.overrideWithValue` 注入。
/// 未 override 时抛出，避免误用未初始化的 SP。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
    'sharedPreferencesProvider must be overridden in main()',
  );
});
