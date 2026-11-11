import 'dart:async';

import 'package:dio/dio.dart';
import 'package:loop_back/features/audio_import/local_audio_file_picker.dart';
import 'package:loop_back/features/audio_import/subtitle_pairing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('top.loop-back/local_audio_picker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 通道收到的调用记录，供断言方法名与参数。
  final calls = <MethodCall>[];

  /// 让通道按方法名回传固定结果；未列出的方法回传 null。
  void mockChannel(Map<String, Object?> responses) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final response = responses[call.method];
      if (response is Exception) throw response;
      return response;
    });
  }

  /// 让通道对 `pickAudioFiles` 回传 [files]（null 表示用户取消）。
  void mockPickResult(List<Object?>? files) {
    mockChannel({'pickAudioFiles': files});
  }

  tearDown(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('目录协议只接收直接文件，子目录只计数', () async {
    mockChannel({
      'pickDirectory': {
        'name': 'Lessons',
        'children': [
          {
            'uri': 'content://tree/1',
            'name': '1.mp3',
            'size': 42,
            'isDirectory': false,
          },
          {
            'uri': 'content://tree/sub',
            'name': 'sub',
            'size': 0,
            'isDirectory': true,
          },
        ],
      },
    });
    final directory = await AndroidLocalAudioFilePicker(
      channel: channel,
    ).pickDirectory();
    expect(directory?.name, 'Lessons');
    expect(directory?.files.single.name, '1.mp3');
    expect(directory?.ignoredDirectories, 1);
    expect(calls.map((c) => c.method), ['pickDirectory']);
  });

  test('目录取消返回 null，畸形条目拒绝', () async {
    mockChannel({'pickDirectory': null});
    expect(
      await AndroidLocalAudioFilePicker(channel: channel).pickDirectory(),
      isNull,
    );
    mockChannel({
      'pickDirectory': {
        'name': 'Lessons',
        'children': [
          {'name': 'bad', 'isDirectory': 'false'},
        ],
      },
    });
    await expectLater(
      AndroidLocalAudioFilePicker(channel: channel).pickDirectory(),
      throwsA(isA<LocalAudioFilePickerException>()),
    );
  });

  test('将原生回传的元数据映射为 PlatformFile', () async {
    mockPickResult(<Object?>[
      <Object?, Object?>{
        'uri': 'content://downloads/1',
        'name': 'audio.mp3',
        'size': 42,
      },
    ]);

    final result = await AndroidLocalAudioFilePicker(
      channel: channel,
    ).pickFiles();

    expect(result, isNotNull);
    final file = result!.files.single;
    expect(file.name, 'audio.mp3');
    expect(file.identifier, 'content://downloads/1');
    expect(file.size, 42);
    // 选择阶段不落盘，Android 上没有可直接打开的文件路径。
    expect(file.path, isNull);
  });

  test('选择阶段不复制文件，只发起一次元数据调用', () async {
    // 回归防线：原生曾无条件把每个选中项抄进 cache，选中几个 apk 就要等几百 MB 抄完。
    mockPickResult(<Object?>[
      <Object?, Object?>{
        'uri': 'content://downloads/1',
        'name': 'app.apk',
        'size': 95687391,
      },
    ]);

    await AndroidLocalAudioFilePicker(channel: channel).pickFiles();

    expect(calls.map((call) => call.method), ['pickAudioFiles']);
  });

  test('取消选择时返回 null', () async {
    mockPickResult(null);

    final result = await AndroidLocalAudioFilePicker(
      channel: channel,
    ).pickFiles();

    expect(result, isNull);
  });

  test('空选择结果按取消处理', () async {
    mockPickResult(<Object?>[]);

    final result = await AndroidLocalAudioFilePicker(
      channel: channel,
    ).pickFiles();

    expect(result, isNull);
  });

  test('拒绝原生层回传的空文件名，避免 Dart 类型异常', () async {
    mockPickResult(<Object?>[
      <Object?, Object?>{
        'uri': 'content://downloads/1',
        'name': null,
        'size': 42,
      },
    ]);

    await expectLater(
      AndroidLocalAudioFilePicker(channel: channel).pickFiles(),
      throwsA(isA<LocalAudioFilePickerException>()),
    );
  });

  test('拒绝原生层回传的空 URI，避免后续读取无凭据', () async {
    mockPickResult(<Object?>[
      <Object?, Object?>{'uri': '', 'name': 'a.mp3', 'size': 42},
    ]);

    await expectLater(
      AndroidLocalAudioFilePicker(channel: channel).pickFiles(),
      throwsA(isA<LocalAudioFilePickerException>()),
    );
  });

  test('拒绝原生层回传的非法体积', () async {
    mockPickResult(<Object?>[
      <Object?, Object?>{
        'uri': 'content://downloads/1',
        'name': 'a.mp3',
        'size': -1,
      },
    ]);

    await expectLater(
      AndroidLocalAudioFilePicker(channel: channel).pickFiles(),
      throwsA(isA<LocalAudioFilePickerException>()),
    );
  });

  test('原生层保真回传扩展名，不受支持的格式仍被白名单拒绝', () async {
    // 回归防线：原生侧一度会按 MIME / 文件头把 movie.mp4 改写成 movie.m4a，
    // 使其绕过白名单被当成音频导入。文件名必须原样透传。
    mockPickResult(<Object?>[
      <Object?, Object?>{
        'uri': 'content://downloads/1',
        'name': 'movie.mp4',
        'size': 1,
      },
      <Object?, Object?>{
        'uri': 'content://downloads/2',
        'name': 'talk.mp3',
        'size': 2,
      },
    ]);

    final result = await AndroidLocalAudioFilePicker(
      channel: channel,
    ).pickFiles();

    final names = result!.files.map((file) => file.name);
    expect(names, ['movie.mp4', 'talk.mp3']);

    final classification = classifyImportFiles(names);
    expect(classification.audioNames, ['talk.mp3']);
    expect(classification.videoNames, ['movie.mp4']);
    expect(classification.rejectedExtensions, isEmpty);
  });

  test('readBytes 按 URI 取字节', () async {
    final data = Uint8List.fromList([1, 2, 3]);
    mockChannel({'readBytes': data});

    final bytes = await AndroidLocalAudioFilePicker(
      channel: channel,
    ).readBytes('content://downloads/1');

    expect(bytes, data);
    expect(calls.single.arguments, {'uri': 'content://downloads/1'});
  });

  test('readBytes 拿到空结果时报错而非静默返回空内容', () async {
    mockChannel({'readBytes': null});

    await expectLater(
      AndroidLocalAudioFilePicker(channel: channel).readBytes('content://a'),
      throwsA(isA<LocalAudioFilePickerException>()),
    );
  });

  test('copyToFile 把 URI 与目标路径一并下发', () async {
    mockChannel({'copyToFile': null});

    await AndroidLocalAudioFilePicker(channel: channel).copyToFile(
      'content://downloads/1',
      '/data/tmp/audio_import/1-a.mp3',
      cancelToken: CancelToken(),
    );

    expect(calls.single.method, 'copyToFile');
    expect(
      calls.single.arguments,
      allOf(
        containsPair('uri', 'content://downloads/1'),
        containsPair('targetPath', '/data/tmp/audio_import/1-a.mp3'),
        containsPair('operationId', isA<String>()),
      ),
    );
  });

  test('copyToFile 的原生错误向上传播，不被静默吞掉', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'audio_picker_copy_failed');
    });

    await expectLater(
      AndroidLocalAudioFilePicker(channel: channel).copyToFile(
        'content://a',
        '/data/tmp/a.mp3',
        cancelToken: CancelToken(),
      ),
      throwsA(isA<PlatformException>()),
    );
  });

  test('取消复制时通知原生任务并向调用方传播取消', () async {
    final copyStarted = Completer<void>();
    final copyResult = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'copyToFile') {
        copyStarted.complete();
        await copyResult.future;
        return;
      }
      if (call.method == 'cancelCopyToFile') {
        copyResult.completeError(PlatformException(code: 'cancelled'));
        return null;
      }
      return null;
    });

    final cancelToken = CancelToken();
    final copy = AndroidLocalAudioFilePicker(channel: channel).copyToFile(
      'content://downloads/1',
      '/data/tmp/audio_import/1-a.mp3',
      cancelToken: cancelToken,
    );
    await copyStarted.future;
    cancelToken.cancel('user-cancelled');

    await expectLater(copy, throwsA(isA<DioException>()));
    expect(calls.map((call) => call.method), [
      'copyToFile',
      'cancelCopyToFile',
    ]);
  });
}
