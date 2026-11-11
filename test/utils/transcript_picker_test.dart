import 'dart:convert';

import 'package:loop_back/services/subtitle_parser.dart';
import 'package:loop_back/utils/transcript_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const charsetChannel = MethodChannel('charset_converter');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(charsetChannel, (call) async {
          if (call.method != 'decode') return null;
          final args = call.arguments as Map<Object?, Object?>;
          final charset = (args['charset'] as String).toLowerCase();
          final rawData = args['data'] as Uint8List;
          final data = rawData.isNotEmpty && rawData.last == 0
              ? Uint8List.sublistView(rawData, 0, rawData.length - 1)
              : rawData;
          final text = _fixtureDecodedText(charset, data);
          if (text == null) {
            throw PlatformException(
              code: 'decode_failed',
              message: 'No mock decoder for $charset',
            );
          }
          return text;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(charsetChannel, null);
  });

  group('decodeTranscriptBytes', () {
    test('保留 UTF-8 字幕内容', () async {
      final content = [
        '1',
        '00:00:00,000 --> 00:00:01,000',
        'Hello, 世界',
        '',
      ].join('\n');

      final result = await decodeTranscriptBytes(utf8.encode(content));

      expect(result.text, content);
      expect(result.charset, 'utf-8');
    });

    test('UTF-8 BOM 字幕去除 BOM', () async {
      final content = '1\n00:00:00,000 --> 00:00:01,000\nHello\n';

      final result = await decodeTranscriptBytes([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(content),
      ]);

      expect(result.text, content);
      expect(result.charset, 'utf-8-bom');
    });

    test('UTF-16 LE BOM 字幕正常解码', () async {
      const content = '1\n00:00:00,000 --> 00:00:01,000\n你好\n';

      final result = await decodeTranscriptBytes(_utf16LeBom(content));

      expect(result.text, content);
      expect(result.charset, 'utf-16le-bom');
    });

    test('UTF-8 失败时按 Windows-1252 解码 smart quotes', () async {
      final bytes = <int>[
        ...ascii.encode('1\n00:00:00,000 --> 00:00:01,000\nIt'),
        0x92,
        ...ascii.encode('s a test '),
        0x96,
        ...ascii.encode(' really.\n'),
      ];

      final result = await decodeTranscriptBytes(bytes);

      expect(
        result.text,
        '1\n00:00:00,000 --> 00:00:01,000\nIt’s a test – really.\n',
      );
      expect(result.charset, 'windows-1252');
    });

    test('GB18030 中文字幕优先于 Windows-1252 乱码', () async {
      final result = await decodeTranscriptBytes(_gb18030ChineseSrt);

      expect(result.text, '1\n00:00:00,000 --> 00:00:01,000\n你好，世界\n');
      expect(result.charset, 'gb18030');
    });

    test('Big5 繁体中文字幕正常解码', () async {
      final result = await decodeTranscriptBytes(_big5TraditionalSrt);

      expect(result.text, '1\n00:00:00,000 --> 00:00:01,000\n繁體字幕\n');
      expect(result.charset, 'big5');
    });

    test('Shift-JIS 日文字幕正常解码', () async {
      final result = await decodeTranscriptBytes(_shiftJisJapaneseSrt);

      expect(result.text, '1\n00:00:00,000 --> 00:00:01,000\nこんにちは\n');
      expect(result.charset, 'shift_jis');
    });

    test('EUC-KR 韩文字幕正常解码', () async {
      final result = await decodeTranscriptBytes(_eucKrKoreanSrt);

      expect(result.text, '1\n00:00:00,000 --> 00:00:01,000\n안녕\n');
      expect(result.charset, 'euc-kr');
    });
  });

  group('normalizeSubtitleToSrt', () {
    test('SRT 原样规范化并可往返解析', () async {
      const srt = '1\n00:00:01,000 --> 00:00:02,000\nHello\n';
      final normalized = await normalizeSubtitleToSrt(srt, ext: 'srt');

      final sentences = await SubtitleParser.parseSubtitleStrictString(
        normalized,
      );
      expect(sentences.length, 1);
      expect(sentences.first.text, 'Hello');
    });

    test('VTT 转成合法 SRT', () async {
      const vtt =
          'WEBVTT\n\n'
          '00:00:01.000 --> 00:00:02.000\nHello\n\n'
          '00:00:02.000 --> 00:00:03.000\nWorld\n';
      final srt = await normalizeSubtitleToSrt(vtt, ext: 'vtt');

      // 产物是标准 SRT（逗号毫秒分隔），且能被 SRT 解析器读回。
      expect(srt.contains('00:00:01,000 --> 00:00:02,000'), isTrue);
      final sentences = await SubtitleParser.parseSubtitleStrictString(srt);
      expect(sentences.map((s) => s.text).toList(), ['Hello', 'World']);
    });

    test('LRC 转成合法 SRT，末句取音频时长', () async {
      const lrc = '[00:01.00]Hello\n[00:03.00]World';
      final srt = await normalizeSubtitleToSrt(
        lrc,
        ext: 'lrc',
        audioDuration: const Duration(seconds: 10),
      );

      final sentences = await SubtitleParser.parseSubtitleStrictString(srt);
      expect(sentences.map((s) => s.text).toList(), ['Hello', 'World']);
      expect(sentences[0].startTime, const Duration(seconds: 1));
      expect(sentences[1].endTime, const Duration(seconds: 10));
    });

    test('非法内容抛 SubtitleParseException', () async {
      expect(
        () => normalizeSubtitleToSrt('not a subtitle', ext: 'lrc'),
        throwsA(isA<SubtitleParseException>()),
      );
    });

    test('空扩展名按 SRT 处理（兼容注入型 picker 默认 ext）', () async {
      const srt = '1\n00:00:01,000 --> 00:00:02,000\nHi\n';
      final normalized = await normalizeSubtitleToSrt(srt, ext: '');
      final sentences = await SubtitleParser.parseSubtitleStrictString(
        normalized,
      );
      expect(sentences.single.text, 'Hi');
    });

    test('大写扩展名不区分大小写', () async {
      const srt = '1\n00:00:01,000 --> 00:00:02,000\nHi\n';
      final normalized = await normalizeSubtitleToSrt(srt, ext: 'SRT');
      expect(normalized.contains('00:00:01,000 --> 00:00:02,000'), isTrue);
    });
  });
}

String? _fixtureDecodedText(String charset, Uint8List data) {
  if (charset == 'windows-1252' || charset == 'iso-8859-1') {
    return _decodeWindows1252ForTest(data);
  }
  if (charset == 'gb18030' && _sameBytes(data, _gb18030ChineseSrt)) {
    return '1\n00:00:00,000 --> 00:00:01,000\n你好，世界\n';
  }
  if (charset == 'big5' && _sameBytes(data, _big5TraditionalSrt)) {
    return '1\n00:00:00,000 --> 00:00:01,000\n繁體字幕\n';
  }
  if (charset == 'shift_jis' && _sameBytes(data, _shiftJisJapaneseSrt)) {
    return '1\n00:00:00,000 --> 00:00:01,000\nこんにちは\n';
  }
  if (charset == 'euc-kr' && _sameBytes(data, _eucKrKoreanSrt)) {
    return '1\n00:00:00,000 --> 00:00:01,000\n안녕\n';
  }
  return null;
}

bool _sameBytes(Uint8List actual, List<int> expected) {
  if (actual.length != expected.length) return false;
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i]) return false;
  }
  return true;
}

String _decodeWindows1252ForTest(List<int> bytes) {
  const overrides = <int, int>{
    0x80: 0x20AC,
    0x82: 0x201A,
    0x83: 0x0192,
    0x84: 0x201E,
    0x85: 0x2026,
    0x86: 0x2020,
    0x87: 0x2021,
    0x88: 0x02C6,
    0x89: 0x2030,
    0x8A: 0x0160,
    0x8B: 0x2039,
    0x8C: 0x0152,
    0x8E: 0x017D,
    0x91: 0x2018,
    0x92: 0x2019,
    0x93: 0x201C,
    0x94: 0x201D,
    0x95: 0x2022,
    0x96: 0x2013,
    0x97: 0x2014,
    0x98: 0x02DC,
    0x99: 0x2122,
    0x9A: 0x0161,
    0x9B: 0x203A,
    0x9C: 0x0153,
    0x9E: 0x017E,
    0x9F: 0x0178,
  };
  return String.fromCharCodes(bytes.map((byte) => overrides[byte] ?? byte));
}

List<int> _utf16LeBom(String text) {
  final bytes = <int>[0xFF, 0xFE];
  for (final unit in text.codeUnits) {
    bytes.add(unit & 0xFF);
    bytes.add(unit >> 8);
  }
  return bytes;
}

const _gb18030ChineseSrt = <int>[
  0x31,
  0x0A,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x30,
  0x2C,
  0x30,
  0x30,
  0x30,
  0x20,
  0x2D,
  0x2D,
  0x3E,
  0x20,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x31,
  0x2C,
  0x30,
  0x30,
  0x30,
  0x0A,
  0xC4,
  0xE3,
  0xBA,
  0xC3,
  0xA3,
  0xAC,
  0xCA,
  0xC0,
  0xBD,
  0xE7,
  0x0A,
];

const _big5TraditionalSrt = <int>[
  0x31,
  0x0A,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x30,
  0x2C,
  0x30,
  0x30,
  0x30,
  0x20,
  0x2D,
  0x2D,
  0x3E,
  0x20,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x31,
  0x2C,
  0x30,
  0x30,
  0x30,
  0x0A,
  0xC1,
  0x63,
  0xC5,
  0xE9,
  0xA6,
  0x72,
  0xB9,
  0xF5,
  0x0A,
];

const _shiftJisJapaneseSrt = <int>[
  0x31,
  0x0A,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x30,
  0x2C,
  0x30,
  0x30,
  0x30,
  0x20,
  0x2D,
  0x2D,
  0x3E,
  0x20,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x31,
  0x2C,
  0x30,
  0x30,
  0x30,
  0x0A,
  0x82,
  0xB1,
  0x82,
  0xF1,
  0x82,
  0xC9,
  0x82,
  0xBF,
  0x82,
  0xCD,
  0x0A,
];

const _eucKrKoreanSrt = <int>[
  0x31,
  0x0A,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x30,
  0x2C,
  0x30,
  0x30,
  0x30,
  0x20,
  0x2D,
  0x2D,
  0x3E,
  0x20,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x31,
  0x2C,
  0x30,
  0x30,
  0x30,
  0x0A,
  0xBE,
  0xC8,
  0xB3,
  0xE7,
  0x0A,
];
