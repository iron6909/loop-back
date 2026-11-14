import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/services/asr/asr_model_catalog.dart'
    show AsrDownloadSource, AsrPublicResourceLayout;
import 'package:loop_back/services/tts/tts_shared_resource_catalog.dart';

void main() {
  group('espeak-ng-data 共享资源身份', () {
    test('从 HF dataset 下载（可走 hf-mirror），不再固定 GitHub 发布资产', () {
      final resource = ttsEspeakNgDataResource;
      final file = resource.files.single;
      expect(resource.layout, AsrPublicResourceLayout.huggingFaceDatasetResolve);

      expect(
        resource.fileUri(AsrDownloadSource.huggingFace, file).toString(),
        'https://huggingface.co/datasets/banko3/loop-back/resolve/'
        '$ttsEspeakNgDataRevision/espeak-ng-data.tar.gz',
      );
      // 镜像只切域名，版本与路径不变。
      expect(
        resource.fileUri(AsrDownloadSource.huggingFaceMirror, file).toString(),
        'https://hf-mirror.com/datasets/banko3/loop-back/resolve/'
        '$ttsEspeakNgDataRevision/espeak-ng-data.tar.gz',
      );
    });

    test('摘要与字节数钉死（换文件必须显式改这里）', () {
      final file = ttsEspeakNgDataResource.files.single;
      expect(file.name, 'espeak-ng-data.tar.gz');
      expect(file.sizeBytes, 8986848);
      expect(
        file.sha256,
        '6ebdff81e71e67e6cc4caac37a28ebfe38b364db5cbac66746efc94403abb8a2',
      );
    });
  });
}
