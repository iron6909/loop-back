/// ASR 资源发布规格目录。
///
/// 本文件是 ASR 资源身份的唯一来源：模型 ID、固定公开 revision、逐文件
/// SHA-256、字节数、许可与共享依赖。三个 Whisper 英语模型与共享 Silero VAD
/// 都从固定公开来源逐文件下载，ASR 安装流程不再请求 EchoLoop 资源服务。
///
/// 摘要与大小于 2026-11-07 通过独立下载核对：Hugging Face 与 hf-mirror.com
/// 返回同一 revision 的相同字节（逐文件 SHA-256 一致），VAD 取自 k2-fsa/
/// sherpa-onnx 的 GitHub 发布资产。权重许可为 OpenAI Whisper 的 MIT；
/// ONNX 转换与发布来自 sherpa-onnx（Apache-2.0）。权重文件只按摘要校验下载，
/// 不进入仓库。
library;

/// 所有 Whisper 模型共享的 VAD 资源 ID。
const vadModelId = 'silero-vad';

/// 公开下载源。上游与镜像只改变下载域名，不改变被信任的版本与摘要。
enum AsrDownloadSource {
  /// 默认公开上游。
  huggingFace('Hugging Face', 'https://huggingface.co'),

  /// 明确标识的公开镜像，内容与上游同版本同摘要。
  huggingFaceMirror('hf-mirror.com', 'https://hf-mirror.com');

  const AsrDownloadSource(this.label, this.host);

  /// 界面展示名称。
  final String label;

  /// 资源所在域名（不含路径）。
  final String host;
}

/// 公开资源的目录布局，决定文件 URL 的拼接方式。
enum AsrPublicResourceLayout {
  /// `<域名>/<repository>/resolve/<revision>/<file>`：Hugging Face 及其镜像通用。
  huggingFaceResolve,

  /// `<域名>/datasets/<repository>/resolve/<revision>/<file>`：Hugging Face
  /// 数据集仓库（词典/发音库等整包资源）及其镜像通用。
  huggingFaceDatasetResolve,

  /// `<域名>/<repository>/releases/download/<revision>/<file>`：GitHub 发布资产。
  githubReleaseAsset,
}

/// 公开资源中的单个文件及其校验依据。
class AsrResourceFile {
  const AsrResourceFile({
    required this.name,
    required this.sha256,
    required this.sizeBytes,
  });

  /// 安装后的文件名。
  final String name;

  /// 上游公布的 SHA-256（独立下载核对后记录）。
  final String sha256;

  /// 文件字节数，用于下载进度与安装后大小。
  final int sizeBytes;
}

/// 一个 ASR 资源的固定公开身份：模型本体与共享依赖共用同一份描述。
class AsrPublicResourceSpec {
  const AsrPublicResourceSpec({
    required this.id,
    required this.repository,
    required this.revision,
    required this.layout,
    required this.license,
    required this.files,
    this.dependencies = const [],
  });

  /// 资源 ID，同时作为安装目录名。
  final String id;

  /// 需要同时安装的共享依赖资源 ID。
  final List<String> dependencies;

  /// 公开仓库，如 `csukuangfj/sherpa-onnx-whisper-tiny.en`。
  final String repository;

  /// 固定 revision：Hugging Face 为 commit，GitHub 发布为发布 tag。
  final String revision;

  /// 文件目录布局。
  final AsrPublicResourceLayout layout;

  /// 上游许可标识。
  final String license;

  /// 需要下载的全部文件。
  final List<AsrResourceFile> files;

  /// 预计下载字节数，用于界面预估。
  int get estimatedDownloadBytes =>
      files.fold(0, (sum, file) => sum + file.sizeBytes);

  /// 指定下载源下的文件目录 URI。
  ///
  /// GitHub 发布资产没有已核实的等价镜像，选择镜像时仍返回上游地址：
  /// 镜像只影响有同版本镜像的资源，不允许猜一个未核实的下载地址。
  Uri fileUri(AsrDownloadSource source, AsrResourceFile file) {
    final directory = switch (layout) {
      AsrPublicResourceLayout.huggingFaceResolve =>
        '${source.host}/$repository/resolve/$revision/',
      AsrPublicResourceLayout.huggingFaceDatasetResolve =>
        '${source.host}/datasets/$repository/resolve/$revision/',
      AsrPublicResourceLayout.githubReleaseAsset =>
        'https://github.com/$repository/releases/download/$revision/',
    };
    return Uri.parse('$directory${file.name}');
  }
}

/// 三档 Whisper 英语 INT8 ONNX 模型与共享 Silero VAD 的固定公开来源。
///
/// Base、Small 的公开文件与旧 EchoLoop 归档内的文件字节完全一致（逐文件
/// SHA-256 相同），因此旧归档安装与更早的逐文件安装仍被视为同一身份，
/// 升级后不会重下已安装的模型。
///
/// VAD 已知限制：`asr-models` 发布 tag 是该项目公开该文件的唯一固定位置，
/// 发布资产理论上可被替换，因此安装时始终逐文件校验 SHA-256——上游若替换内容
/// 只会得到校验失败，不会安装身份不明的权重。若日后出现 commit 级固定来源，
/// 应改用该来源并把这里的 revision 换掉。
final asrPublicResourceCatalog = <String, AsrPublicResourceSpec>{
  'whisper-tiny-en-int8': AsrPublicResourceSpec(
    id: 'whisper-tiny-en-int8',
    repository: 'csukuangfj/sherpa-onnx-whisper-tiny.en',
    revision: 'd026532c022fa99fd789d6b32446a1df7b6bfc43',
    layout: AsrPublicResourceLayout.huggingFaceResolve,
    license: 'MIT',
    files: const [
      AsrResourceFile(
        name: 'tiny.en-encoder.int8.onnx',
        sha256:
            '0ce578b827c94a961aacb8fa14b02f096504b337e5c94be37c36238cbe3e8bc6',
        sizeBytes: 12937772,
      ),
      AsrResourceFile(
        name: 'tiny.en-decoder.int8.onnx',
        sha256:
            '06c0e6ff6348d427e51839219d1c886c18cfdf411e629e33f5e1679bff9c1527',
        sizeBytes: 89853865,
      ),
      AsrResourceFile(
        name: 'tiny.en-tokens.txt',
        sha256:
            '306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930',
        sizeBytes: 835554,
      ),
    ],
    dependencies: const [vadModelId],
  ),
  'whisper-base-en-int8': AsrPublicResourceSpec(
    id: 'whisper-base-en-int8',
    repository: 'csukuangfj/sherpa-onnx-whisper-base.en',
    revision: '59eea950fc76df2453efb57e6c0fd334548e8ffe',
    layout: AsrPublicResourceLayout.huggingFaceResolve,
    license: 'MIT',
    files: const [
      AsrResourceFile(
        name: 'base.en-encoder.int8.onnx',
        sha256:
            'ef6b936f4c9b1d90a3b68634b60c4ed8576b26172b33c2535ec0e933c9edb823',
        sizeBytes: 29120534,
      ),
      AsrResourceFile(
        name: 'base.en-decoder.int8.onnx',
        sha256:
            'f7162ad6db2dbef16cfaeaa7f945b9d7dd9c1b8d472f6aca82f2273d185e4d41',
        sizeBytes: 130669978,
      ),
      AsrResourceFile(
        name: 'base.en-tokens.txt',
        sha256:
            '306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930',
        sizeBytes: 835554,
      ),
    ],
    dependencies: const [vadModelId],
  ),
  'whisper-small-en-int8': AsrPublicResourceSpec(
    id: 'whisper-small-en-int8',
    repository: 'csukuangfj/sherpa-onnx-whisper-small.en',
    revision: 'd9533f69affd85061aee349af7fea5cb2996dbbe',
    layout: AsrPublicResourceLayout.huggingFaceResolve,
    license: 'MIT',
    files: const [
      AsrResourceFile(
        name: 'small.en-encoder.int8.onnx',
        sha256:
            '8bdac288f369aa94ee2194059238c465ed82ea9d47ee8fa4a8c0a891873e462f',
        sizeBytes: 112442483,
      ),
      AsrResourceFile(
        name: 'small.en-decoder.int8.onnx',
        sha256:
            '710ccf890e10f3faa15f51ec346081a2723c9f3adb6e4da81c6573a5a6f877fb',
        sizeBytes: 262223042,
      ),
      AsrResourceFile(
        name: 'small.en-tokens.txt',
        sha256:
            '306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930',
        sizeBytes: 835554,
      ),
    ],
    dependencies: const [vadModelId],
  ),
  vadModelId: AsrPublicResourceSpec(
    id: vadModelId,
    repository: 'k2-fsa/sherpa-onnx',
    revision: 'asr-models',
    layout: AsrPublicResourceLayout.githubReleaseAsset,
    license: 'MIT',
    files: const [
      AsrResourceFile(
        name: 'silero_vad.onnx',
        sha256:
            '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
        sizeBytes: 643854,
      ),
    ],
  ),
};
