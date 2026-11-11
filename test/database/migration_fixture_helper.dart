import 'dart:io';

import 'package:drift/native.dart';
import 'package:loop_back/database/app_database.dart';

/// 为历史迁移 fixture 预置完整当前 schema，避免后续迁移回填访问缺失业务表。
Future<void> seedCurrentSchema(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  await db.customSelect('SELECT 1').get();
  await db.close();
}
