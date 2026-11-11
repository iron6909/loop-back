import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:loop_back/services/ndjson_stream.dart';
import 'package:flutter_test/flutter_test.dart';

/// 把字符串按给定分片切成字节 chunk 流（模拟网络分片）
Stream<Uint8List> _chunks(List<String> parts) =>
    Stream.fromIterable(parts.map((p) => Uint8List.fromList(utf8.encode(p))));

void main() {
  test('多帧按行解析，顺序保持', () async {
    final result = await decodeNdjson(
      _chunks([
        '${jsonEncode({'a': 1})}\n${jsonEncode({'a': 2})}\n',
      ]),
    ).toList();

    expect(result, [
      {'a': 1},
      {'a': 2},
    ]);
  });

  test('跨 chunk 的行被正确拼接', () async {
    // 一行 JSON 被切成两个 chunk（在中间断开）
    final result = await decodeNdjson(
      _chunks(['{"head', 'word":"run"}\n']),
    ).toList();

    expect(result, [
      {'headword': 'run'},
    ]);
  });

  test('末行无尾随 \\n 也吐出', () async {
    final result = await decodeNdjson(
      _chunks([
        '${jsonEncode({'a': 1})}\n${jsonEncode({'a': 2})}',
      ]),
    ).toList();

    expect(result.length, 2);
    expect(result.last, {'a': 2});
  });

  test('跨 chunk 的多字节 UTF-8 字符不乱码', () async {
    // “你好” 的 UTF-8 编码在 chunk 边界处被切断
    final full = utf8.encode('${jsonEncode({'t': '你好世界'})}\n');
    final mid = full.length ~/ 2;
    final result = await decodeNdjson(
      Stream.fromIterable([
        Uint8List.fromList(full.sublist(0, mid)),
        Uint8List.fromList(full.sublist(mid)),
      ]),
    ).toList();

    expect(result, [
      {'t': '你好世界'},
    ]);
  });

  test('空行被跳过', () async {
    final result = await decodeNdjson(
      _chunks([
        '\n\n${jsonEncode({'a': 1})}\n\n',
      ]),
    ).toList();

    expect(result, [
      {'a': 1},
    ]);
  });

  test('__error 帧原样 yield（判定交由上层）', () async {
    final result = await decodeNdjson(
      _chunks([
        '${jsonEncode({'__error': 'unavailable'})}\n',
      ]),
    ).toList();

    expect(result, [
      {'__error': 'unavailable'},
    ]);
  });

  test('onLine 收到每条非空原始行，不影响解析', () async {
    final lines = <String>[];

    final result = await decodeNdjson(
      _chunks([
        '\n${jsonEncode({'a': 1})}\n  ${jsonEncode({'b': 2})}  \n',
      ]),
      onLine: lines.add,
    ).toList();

    expect(result, [
      {'a': 1},
      {'b': 2},
    ]);
    expect(lines, [
      jsonEncode({'a': 1}),
      jsonEncode({'b': 2}),
    ]);
  });

  test('onLine 抛错不影响解析', () async {
    final result = await decodeNdjson(
      _chunks([
        '${jsonEncode({'a': 1})}\n',
      ]),
      onLine: (_) => throw StateError('log failed'),
    ).toList();

    expect(result, [
      {'a': 1},
    ]);
  });

  test('损坏 JSON 行抛 FormatException', () async {
    await expectLater(
      decodeNdjson(_chunks(['{"a":\n'])).toList(),
      throwsA(isA<FormatException>()),
    );
  });

  test('非 Map 行（如数组/标量）抛 FormatException', () async {
    await expectLater(
      decodeNdjson(_chunks(['123\n'])).toList(),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      decodeNdjson(_chunks(['[1,2]\n'])).toList(),
      throwsA(isA<FormatException>()),
    );
  });

  Uint8List lineBytes(Map<String, dynamic> m) =>
      Uint8List.fromList(utf8.encode('${jsonEncode(m)}\n'));

  test('idleTimeout：帧间空闲超过阈值抛 TimeoutException', () async {
    final controller = StreamController<Uint8List>();
    // 从不吐字节 → 空闲超时应触发。
    final future = decodeNdjson(
      controller.stream,
      idleTimeout: const Duration(milliseconds: 50),
    ).toList();

    await expectLater(future, throwsA(isA<TimeoutException>()));
    await controller.close();
  });

  test('idleTimeout：窗口内持续吐帧不误触发（每帧重置计时）', () async {
    final controller = StreamController<Uint8List>();
    final future = decodeNdjson(
      controller.stream,
      idleTimeout: const Duration(milliseconds: 200),
    ).toList();

    controller.add(lineBytes({'a': 1}));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    controller.add(lineBytes({'a': 2})); // 重置计时，未超时
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await controller.close();

    expect(await future, [
      {'a': 1},
      {'a': 2},
    ]);
  });

  test('idleTimeout 为 null 时不施加超时（默认行为）', () async {
    final controller = StreamController<Uint8List>();
    var settled = false;
    decodeNdjson(
      controller.stream,
    ).toList().then((_) => settled = true).onError((_, __) => settled = true);

    // 停滞远超上例阈值仍不结束/不报错。
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(settled, isFalse);
    await controller.close();
  });
}
