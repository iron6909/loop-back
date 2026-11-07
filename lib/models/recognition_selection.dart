/// 识别用途与方式的领域模型。
///
/// 字幕转录、跟读、复述各自保存识别方式与模型，互不回写；设置页与业务入口
/// 读取同一份选择。在线方式目前只对字幕开放，而且要等该配置通过字幕（片段
/// 时间戳）能力验证后才出现在可选方式里。
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
/// （Apple 的 SFSpeechRecognizer），不宣称一定离线；[online] 使用用户配置的
/// 在线转写服务，模型由语音配置按用途提供。
enum RecognitionMode { local, system, online }

/// 单个用途的识别选择。
class RecognitionSelection {
  const RecognitionSelection({required this.mode, this.localModelId = ''});

  /// 本机方式，绑定一个 Whisper 档位。
  const RecognitionSelection.local(String modelId)
    : this(mode: RecognitionMode.local, localModelId: modelId);

  /// 系统识别方式，不绑定本机模型。
  const RecognitionSelection.system() : this(mode: RecognitionMode.system);

  /// 在线转写方式；模型由语音配置按用途提供，不绑定本机模型。
  const RecognitionSelection.online() : this(mode: RecognitionMode.online);

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
  /// 复述复用转写时用它比对来源：本机方式绑定模型档位，系统方式绑定平台识别，
  /// 在线方式绑定当前在线配置。不能用文件路径或转录来源标签代替，否则换了
  /// 模型也会被当成同一结果。
  String get recognitionIdentity => switch (mode) {
    RecognitionMode.local => 'local:$localModelId',
    RecognitionMode.system => 'system',
    // 在线模型属于语音配置，不重复存一份；身份只表达「走了在线方式」。
    RecognitionMode.online => 'online',
  };

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
