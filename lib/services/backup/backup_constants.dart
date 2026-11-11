/// LoopBack 备份文件扩展名。
const backupFileExtension = 'elbak';

/// 判断文件名是否为当前备份格式或 Android 历史保存链路追加 ZIP 后缀的格式。
bool isBackupFileName(String name) {
  final normalized = name.toLowerCase();
  return normalized.endsWith('.$backupFileExtension') ||
      normalized.endsWith('.$backupFileExtension.zip');
}
