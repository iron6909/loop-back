/// 通用流式对象累积层单测
///
/// 不依赖任何业务模型：用 `Map echo`（fromJson 原样返回累积快照的深拷贝）验证
/// [accumulateNdjsonObject] 的帧派发语义，用 [setPath] 直接验证路径拼装。
library;

import 'dart:async';

import 'package:loop_back/services/ndjson_object_stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('setPath', () {
    test('嵌套 Map 逐段建容器后赋值', () {
      final root = <String, dynamic>{};
      setPath(root, ['a', 'b', 'c'], 1);
      expect(root, {
        'a': {
          'b': {'c': 1},
        },
      });
    });

    test('List 下标自动 null 扩容且无空洞', () {
      final root = <String, dynamic>{};
      setPath(root, ['items', 2], 'x');
      expect(root, {
        'items': [null, null, 'x'],
      });
    });

    test('Map 与 List 混合路径', () {
      final root = <String, dynamic>{};
      setPath(root, ['meanings', 0, 'definition'], 'to run');
      setPath(root, ['meanings', 0, 'examples', 1], 'e1');
      expect(root, {
        'meanings': [
          {
            'definition': 'to run',
            'examples': [null, 'e1'],
          },
        ],
      });
    });

    test('空路径为 no-op', () {
      final root = <String, dynamic>{'k': 1};
      setPath(root, [], 99);
      expect(root, {'k': 1});
    });
  });

  group('accumulateNdjsonObject', () {
    // 原样回传累积快照，便于断言累积内容。
    Map<String, dynamic> echo(Map<String, dynamic> acc) =>
        Map<String, dynamic>.from(acc);

    Stream<Map<String, dynamic>> events(List<Map<String, dynamic>> list) =>
        Stream.fromIterable(list);

    test('单批多叶子只 yield 一帧', () async {
      final frames = await accumulateNdjsonObject<Map<String, dynamic>>(
        events([
          {
            'ops': [
              {
                'p': ['a'],
                'v': 1,
              },
              {
                'p': ['b'],
                'v': 2,
              },
            ],
          },
          {'done': true},
        ]),
        fromJson: echo,
      ).toList();

      expect(frames.length, 2); // 一个 ops 帧 + done 帧
      expect(frames.first.value, {'a': 1, 'b': 2});
    });

    test('多批递增累积，非末帧 isFinal=false，done 帧 isFinal=true', () async {
      final frames = await accumulateNdjsonObject<Map<String, dynamic>>(
        events([
          {
            'ops': [
              {
                'p': ['a'],
                'v': 1,
              },
            ],
          },
          {
            'ops': [
              {
                'p': ['b'],
                'v': 2,
              },
            ],
          },
          {'done': true},
        ]),
        fromJson: echo,
      ).toList();

      expect(frames.map((f) => f.isFinal).toList(), [false, false, true]);
      expect(frames[1].value, {'a': 1, 'b': 2});
    });

    test('末帧累积对象不含 done/ops/__error 等协议字段', () async {
      final frames = await accumulateNdjsonObject<Map<String, dynamic>>(
        events([
          {
            'ops': [
              {
                'p': ['x'],
                'v': 1,
              },
            ],
          },
          {'done': true},
        ]),
        fromJson: echo,
      ).toList();

      expect(frames.last.value.keys, ['x']);
    });

    test('__error 帧抛 NdjsonStreamException', () async {
      expect(
        accumulateNdjsonObject<Map<String, dynamic>>(
          events([
            {
              'ops': [
                {
                  'p': ['x'],
                  'v': 1,
                },
              ],
            },
            {'__error': 'unavailable'},
          ]),
          fromJson: echo,
        ).toList(),
        throwsA(isA<NdjsonStreamException>()),
      );
    });

    test('行损坏（FormatException）转 NdjsonStreamException', () async {
      Stream<Map<String, dynamic>> broken() async* {
        yield {
          'ops': [
            {
              'p': ['x'],
              'v': 1,
            },
          ],
        };
        throw const FormatException('corrupt line');
      }

      expect(
        accumulateNdjsonObject<Map<String, dynamic>>(
          broken(),
          fromJson: echo,
        ).toList(),
        throwsA(isA<NdjsonStreamException>()),
      );
    });

    test('帧间空闲超时（TimeoutException）转 NdjsonStreamException', () async {
      Stream<Map<String, dynamic>> stalled() async* {
        yield {
          'ops': [
            {
              'p': ['x'],
              'v': 1,
            },
          ],
        };
        throw TimeoutException('idle', const Duration(seconds: 30));
      }

      await expectLater(
        accumulateNdjsonObject<Map<String, dynamic>>(
          stalled(),
          fromJson: echo,
        ).toList(),
        throwsA(isA<NdjsonStreamException>()),
      );
    });

    test('未知事件被忽略', () async {
      final frames = await accumulateNdjsonObject<Map<String, dynamic>>(
        events([
          {'unknown': 'noise'},
          {
            'ops': [
              {
                'p': ['x'],
                'v': 1,
              },
            ],
          },
          {'done': true},
        ]),
        fromJson: echo,
      ).toList();

      expect(frames.length, 2); // 未知事件不产生帧
      expect(frames.first.value, {'x': 1});
    });
  });
}
