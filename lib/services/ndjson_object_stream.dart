/// 通用流式对象累积层
///
/// 把 NDJSON 增量事件流（[decodeNdjson] 的输出）累积拼装为「逐帧完整对象」流。
/// 与具体业务（词典/句子解析/翻译……）解耦：任意端点只需提供 `T fromJson(Map)`
/// 即可获得 `Stream<StreamFrame<T>>`。
///
/// 帧协议（对齐后端 `apps/app/app/api/v1/stream/_shared.ts`）：
/// - 增量批：`{"ops":[{"p":["meanings",0,"definition"],"v":<scalar>},...]}`，
///   按路径设标量叶子，一批全部应用后只 yield 一帧；
/// - 结束：`{"done":true}` → 末帧 `isFinal=true`；
/// - 错误：`{"__error":...}` 或行损坏（[FormatException]）→ 抛 [NdjsonStreamException]。
///
/// 未知事件忽略（前向兼容）。纯函数式、无状态、不感知取消——取消由上游 Dio 关流
/// 使事件流自然结束，本层不会 yield final 帧，由消费方据此决定不落缓存（止损）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'ndjson_stream.dart';

/// 通用流式对象帧。
///
/// [value] 为「当前累积快照」经 `fromJson` 解析出的完整对象；[isFinal] 仅在收到
/// 后端 `done` 帧的末帧为 true。调用方只有拿到 final 才能把该帧视为可缓存的完整结果。
class StreamFrame<T> {
  /// 当前累积快照解析出的完整对象。
  final T value;

  /// 是否为流正常结束的末帧（收到 `{"done":true}`）。
  final bool isFinal;

  const StreamFrame({required this.value, required this.isFinal});
}

/// 流内错误：收到 `{"__error":...}` 或行损坏时抛出。
///
/// 业务侧可捕获后包装为各自的领域异常（如 `DictionaryStreamException`），
/// 使通用层不感知具体业务语义。
class NdjsonStreamException implements Exception {
  const NdjsonStreamException();

  @override
  String toString() => 'NdjsonStreamException';
}

/// 把 NDJSON 事件流累积拼装为「逐帧完整对象」流。
///
/// [events] 通常为 `decodeNdjson(body.stream)`；[fromJson] 把累积的裸 Map 转为业务
/// 模型（要求防御性解析、缺字段回退空值、永不抛）。
Stream<StreamFrame<T>> accumulateNdjsonObject<T>(
  Stream<Map<String, dynamic>> events, {
  required T Function(Map<String, dynamic>) fromJson,
}) async* {
  final acc = <String, dynamic>{};
  try {
    await for (final ev in events) {
      if (ev.containsKey('__error')) {
        throw const NdjsonStreamException();
      }
      if (ev['done'] == true) {
        yield StreamFrame(value: fromJson(acc), isFinal: true);
        break;
      }
      final ops = ev['ops'];
      if (ops is! List) {
        continue; // 未知事件，忽略（前向兼容）
      }
      // 一行内可能含多个叶子（一次 flush 的批量），全部应用后只 yield 一帧。
      for (final op in ops) {
        if (op is! Map) continue;
        final path = op['p'];
        if (path is List) {
          setPath(acc, path, op['v']);
        }
      }
      yield StreamFrame(value: fromJson(acc), isFinal: false);
    }
  } on FormatException {
    throw const NdjsonStreamException();
  } on TimeoutException {
    // 帧间空闲超时（decodeNdjson 的 idleTimeout）统一归为流内错误，
    // 由消费方按各自领域异常处理，不 yield final 帧 → 止损不落缓存。
    throw const NdjsonStreamException();
  }
}

/// 按路径写入累积对象：沿 [path] 逐段下行，按**下一段类型**自动建容器
/// （下一段是 int → 当前应为 `List` 并扩容到该下标；是 String → 应为 `Map`），
/// 末段直接赋值。生成顺序保证下标从 0 递增无空洞。
@visibleForTesting
void setPath(Map<String, dynamic> root, List<Object?> path, Object? value) {
  if (path.isEmpty) return;
  Object? cur = root;
  for (var i = 0; i < path.length - 1; i++) {
    final seg = path[i];
    final next = path[i + 1];
    final child = _childAt(cur, seg);
    if (next is int) {
      if (child is! List) {
        _assign(cur, seg, <dynamic>[]);
      }
    } else if (child is! Map<String, dynamic>) {
      _assign(cur, seg, <String, dynamic>{});
    }
    cur = _childAt(cur, seg);
  }
  _assign(cur, path.last, value);
}

/// 读取容器 [cur] 在段 [seg]（int 下标 / String 键）处的子节点，越界/缺失回 null。
Object? _childAt(Object? cur, Object? seg) {
  if (seg is int && cur is List) {
    return (seg >= 0 && seg < cur.length) ? cur[seg] : null;
  }
  if (seg is String && cur is Map) {
    return cur[seg];
  }
  return null;
}

/// 向容器 [cur] 的段 [seg] 赋值：List 按需用 null 扩容到 [seg]，Map 直接置键。
void _assign(Object? cur, Object? seg, Object? value) {
  if (seg is int && cur is List) {
    while (cur.length <= seg) {
      cur.add(null);
    }
    cur[seg] = value;
  } else if (seg is String && cur is Map) {
    cur[seg] = value;
  }
}
