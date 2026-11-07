/// 识别用途与方式的领域模型。
///
/// 字幕转录、跟读、复述各自保存识别方式与模型，互不回写；设置页与业务入口
/// 读取同一份选择。在线方式要等对应在线转写与能力验证切片完成，在那之前
/// 不作为可选方式出现，因此这里没有在线分支。
library;

/// 识别用途。
enum RecognitionPurpose {
  /// 学习材料字幕转录：需要片段时间戳。
  subtitle,

  /// 跟读录音：短句评分与最终转写。
  shadowing,

  /// 复述录音：段落转写后交给独立文字服务评估。
  retell,
}

/// 识别方式。
///
/// [local] 使用本机 Whisper 档位；[system] 使用平台自带的语音识别
/// （Apple 的 SFSpeechRecognizer），不宣称一定离线。
enum RecognitionMode { local, system }

/// 单个用途的识别选择。
class RecognitionSelection {
  const RecognitionSelection({required this.mode, this.localModelId = ''});

  /// 本机方式，绑定一个 Whisper 档位。
  const RecognitionSelection.local(String modelId)
    : this(mode: RecognitionMode.local, localModelId: modelId);

  /// 系统识别方式，不绑定本机模型。
  const RecognitionSelection.system() : this(mode: RecognitionMode.system);

  /// 本机方式使用的 Whisper 档位 id。
  ///
  /// 系统方式保留上一次的本机档位，供用户切回本机时沿用。
  final String localModelId;

  /// 当前方式。
  final RecognitionMode mode;

  /// 是否使用本机模型。
  bool get usesLocalModel => mode == RecognitionMode.local;

  /// 实际识别身份。
  ///
  /// 复述复用转写时用它比对来源：本机方式绑定模型档位，系统方式绑定平台识别。
  /// 不能用文件路径或转录来源标签代替，否则换了模型也会被当成同一结果。
  String get recognitionIdentity =>
      usesLocalModel ? 'local:$localModelId' : 'system';

  @override
  bool operator ==(Object other) =>
      other is RecognitionSelection &&
      other.mode == mode &&
      other.localModelId == localModelId;

  @override
  int get hashCode => Object.hash(mode, localModelId);

  @override
  String toString() => 'RecognitionSelection($recognitionIdentity)';
}
