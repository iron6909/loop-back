import 'package:loop_back/services/lrc_parser.dart';
import 'package:loop_back/services/subtitle_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseLrc', () {
    test('标准 LRC：每句结束时间取下一句起点', () {
      const lrc =
          '[00:01.00]Hello\n'
          '[00:03.50]World\n'
          '[00:06.00]End';
      final sentences = parseLrc(
        lrc,
        audioDuration: const Duration(seconds: 10),
      );

      expect(sentences.length, 3);
      expect(sentences[0].text, 'Hello');
      expect(sentences[0].startTime, const Duration(seconds: 1));
      expect(sentences[0].endTime, const Duration(milliseconds: 3500));
      expect(sentences[1].startTime, const Duration(milliseconds: 3500));
      expect(sentences[1].endTime, const Duration(seconds: 6));
    });

    test('末句结束时间取音频总时长', () {
      const lrc = '[00:01.00]A\n[00:02.00]B';
      final sentences = parseLrc(
        lrc,
        audioDuration: const Duration(seconds: 30),
      );

      expect(sentences.last.endTime, const Duration(seconds: 30));
    });

    test('无音频时长时末句用默认间隔兜底', () {
      const lrc = '[00:01.00]A\n[00:02.00]B';
      final sentences = parseLrc(lrc);

      // 末句起点 2s + 默认 5s = 7s。
      expect(sentences.last.endTime, const Duration(seconds: 7));
    });

    test('音频时长早于末句起点时也退回默认间隔', () {
      const lrc = '[00:01.00]A\n[00:20.00]B';
      final sentences = parseLrc(
        lrc,
        audioDuration: const Duration(seconds: 10),
      );

      expect(sentences.last.endTime, const Duration(seconds: 25));
    });

    test('厘秒（2位）与毫秒（3位）小数换算', () {
      const lrc = '[00:01.5]A\n[00:02.25]B\n[00:03.125]C';
      final sentences = parseLrc(
        lrc,
        audioDuration: const Duration(seconds: 10),
      );

      expect(sentences[0].startTime, const Duration(milliseconds: 1500));
      expect(sentences[1].startTime, const Duration(milliseconds: 2250));
      expect(sentences[2].startTime, const Duration(milliseconds: 3125));
    });

    test('支持 hh:mm:ss 时间标签', () {
      const lrc = '[01:02:03.00]Long';
      final sentences = parseLrc(lrc, audioDuration: const Duration(hours: 2));

      expect(
        sentences.first.startTime,
        const Duration(hours: 1, minutes: 2, seconds: 3),
      );
    });

    test('一行多个时间标签生成多条并按时间排序', () {
      const lrc = '[00:05.00][00:01.00]Repeat';
      final sentences = parseLrc(
        lrc,
        audioDuration: const Duration(seconds: 10),
      );

      expect(sentences.length, 2);
      expect(sentences[0].startTime, const Duration(seconds: 1));
      expect(sentences[1].startTime, const Duration(seconds: 5));
      expect(sentences.every((s) => s.text == 'Repeat'), isTrue);
    });

    test('跳过元数据标签，只解析歌词行', () {
      const lrc = '[ar:Artist]\n[ti:Title]\n[00:01.00]Line';
      final sentences = parseLrc(
        lrc,
        audioDuration: const Duration(seconds: 5),
      );

      expect(sentences.length, 1);
      expect(sentences.first.text, 'Line');
    });

    test('offset 正值使歌词提前', () {
      const lrc = '[offset:500]\n[00:02.00]A';
      final sentences = parseLrc(
        lrc,
        audioDuration: const Duration(seconds: 5),
      );

      // 2000 - 500 = 1500ms。
      expect(sentences.first.startTime, const Duration(milliseconds: 1500));
    });

    test('offset 负值使歌词延后', () {
      const lrc = '[offset:-500]\n[00:02.00]A';
      final sentences = parseLrc(
        lrc,
        audioDuration: const Duration(seconds: 5),
      );

      expect(sentences.first.startTime, const Duration(milliseconds: 2500));
    });

    test('空内容抛 empty', () {
      expect(
        () => parseLrc('   \n  '),
        throwsA(
          isA<SubtitleParseException>().having(
            (e) => e.kind,
            'kind',
            SubtitleParseErrorKind.empty,
          ),
        ),
      );
    });

    test('无任何时间行抛 empty', () {
      expect(
        () => parseLrc('just plain text\nno timestamps'),
        throwsA(isA<SubtitleParseException>()),
      );
    });

    test('CRLF 行结尾正常解析', () {
      const lrc = '[00:01.00]A\r\n[00:02.00]B\r\n';
      final sentences = parseLrc(
        lrc,
        audioDuration: const Duration(seconds: 5),
      );
      expect(sentences.length, 2);
      expect(sentences[0].text, 'A');
      expect(sentences[1].text, 'B');
    });

    test('无小数的时间标签 [mm:ss]', () {
      const lrc = '[00:01]A\n[00:03]B';
      final sentences = parseLrc(
        lrc,
        audioDuration: const Duration(seconds: 5),
      );
      expect(sentences[0].startTime, const Duration(seconds: 1));
      expect(sentences[0].endTime, const Duration(seconds: 3));
    });

    test('乱序时间行按时间排序', () {
      const lrc = '[00:03.00]Third\n[00:01.00]First\n[00:02.00]Second';
      final sentences = parseLrc(
        lrc,
        audioDuration: const Duration(seconds: 5),
      );
      expect(sentences.map((s) => s.text).toList(), [
        'First',
        'Second',
        'Third',
      ]);
    });

    test('offset 过大导致负时间被钳制为 0', () {
      const lrc = '[offset:5000]\n[00:01.00]A\n[00:03.00]B';
      final sentences = parseLrc(
        lrc,
        audioDuration: const Duration(seconds: 5),
      );
      // 1000 - 5000 < 0 → 0；下一句 3000 - 5000 < 0 → 0。
      expect(sentences[0].startTime, Duration.zero);
      expect(sentences[1].startTime, Duration.zero);
    });

    test('空行与纯空白行被忽略', () {
      const lrc = '\n   \n[00:01.00]A\n\n[00:02.00]B\n  ';
      final sentences = parseLrc(
        lrc,
        audioDuration: const Duration(seconds: 5),
      );
      expect(sentences.length, 2);
    });

    test('时间标签后无文本的行被忽略', () {
      const lrc = '[00:01.00]\n[00:02.00]Real';
      final sentences = parseLrc(
        lrc,
        audioDuration: const Duration(seconds: 5),
      );
      expect(sentences.length, 1);
      expect(sentences.first.text, 'Real');
    });

    test('同一时间戳多条：结束时间不早于起点', () {
      const lrc = '[00:02.00]A\n[00:02.00]B';
      final sentences = parseLrc(
        lrc,
        audioDuration: const Duration(seconds: 5),
      );
      expect(sentences.length, 2);
      // 第一条 end = 下一条 start（相同 2s），不为负。
      expect(sentences[0].endTime >= sentences[0].startTime, isTrue);
    });
  });
}
