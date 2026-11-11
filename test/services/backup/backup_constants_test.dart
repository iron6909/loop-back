import 'package:loop_back/services/backup/backup_constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isBackupFileName', () {
    test('接受标准 elbak 文件名', () {
      expect(isBackupFileName('loopback_backup_20260810.elbak'), isTrue);
      expect(isBackupFileName('BACKUP.ELBAK'), isTrue);
    });

    test('兼容 Android 历史追加 zip 后缀的文件名', () {
      expect(isBackupFileName('loopback_backup_20260810.elbak.zip'), isTrue);
      expect(isBackupFileName('BACKUP.ELBAK.ZIP'), isTrue);
    });

    test('拒绝其它文件名', () {
      expect(isBackupFileName('loopback_backup.zip'), isFalse);
      expect(isBackupFileName('loopback_backup.elbak.zip.tmp'), isFalse);
    });
  });
}
