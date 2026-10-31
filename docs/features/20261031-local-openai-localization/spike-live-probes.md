# 真实供应商与 Android 探针复现附件

本附件属于 [spike.md](./spike.md) 的 2026-10-31 真实调用运行。代码是隔离探针原文，未加入应用；保留失败版是为了复核观察，不能直接作为产品实现。

将各代码块保存为对应文件名，Dart 文件放同一临时目录；Android 文件放该目录下的 `android/`。`business2.dart` 的绝对 import 和 `.env` 路径按实际 checkout 调整；`.env` 仅放本机，不复制到本附件。需要的变量为 `DeepSeek_APIKEY`、`OpenRouter_APIKEY`、`OpenCode_APIKEY`，值不可打印。

`business.dart` 是初版失败探针，不能根据其退出码判断成功。`business2.dart` 是主要矩阵，失败返回非零。后者动态选出的模型可能随目录变化；复核本次 OpenRouter 结果时，把 `await pickOpenRouterModel(orKey)` 替换为 `'mistralai/mistral-nemo'`。`contrast.dart` 已固定该模型。探针会消耗额度，重跑需沿用相同授权边界；无需反复运行全部文件。

纯 Dart 复现时先切到临时目录，避免 `dart run` 从项目根目录尝试解析 Flutter 依赖：

```powershell
$taskDart = 'D:/Application/Scoop/apps/flutter/current/bin/cache/dart-sdk/bin/dart.exe'
Set-Location (Join-Path $env:TEMP 'echo-loop-spike-a3f1')
& $taskDart run business2.dart
& $taskDart run usage.dart
& $taskDart run contrast.dart
```

## discover.dart

```dart
// [SPIKE-a3f1-b] 供应商连通性与模型目录探测（不发送业务内容）。
// 运行：dart run discover.dart
import 'dart:convert';
import 'dart:io';

const _envPath = 'D:/Workspace/PersonalStudio/loop-back/.env';

Map<String, String> loadEnv() {
  final out = <String, String>{};
  final file = File(_envPath);
  if (!file.existsSync()) return out;
  for (final raw in file.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final idx = line.indexOf('=');
    if (idx < 1) continue;
    var value = line.substring(idx + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    out[line.substring(0, idx).trim()] = value;
  }
  return out;
}

Future<void> main() async {
  final env = loadEnv();
  final providers = <String, ({String base, String key})>{
    'deepseek': (
      base: 'https://api.deepseek.com',
      key: env['DeepSeek_APIKEY'] ?? '',
    ),
    'openrouter': (
      base: 'https://openrouter.ai/api/v1',
      key: env['OpenRouter_APIKEY'] ?? '',
    ),
    'opencode-go': (
      base: 'https://opencode.ai/inference/go/openai/v1',
      key: env['OpenCode_APIKEY'] ?? '',
    ),
  };

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  for (final entry in providers.entries) {
    final name = entry.key;
    final cfg = entry.value;
    stdout.write('$name key=${cfg.key.isEmpty ? 'MISSING' : 'present'} ');
    for (final path in <String>['/models', '/v1/models']) {
      final uri = Uri.parse('${cfg.base}$path');
      try {
        final req = await client.getUrl(uri);
        req.headers.set('Authorization', 'Bearer ${cfg.key}');
        req.headers.set('Accept', 'application/json');
        final res = await req.close().timeout(const Duration(seconds: 25));
        final body = await res.transform(utf8.decoder).join();
        final ids = _modelIds(body);
        print('| $path -> ${res.statusCode} models=${ids.length} '
            'sample=${ids.take(6).join(",")}');
        if (res.statusCode == 200 && ids.isNotEmpty) break;
      } catch (error) {
        print('| $path -> ERROR ${error.runtimeType}');
      }
    }
  }
  client.close(force: true);
}

List<String> _modelIds(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return const [];
    final data = decoded['data'];
    if (data is! List) return const [];
    return [
      for (final item in data)
        if (item is Map && item['id'] is String) item['id'] as String,
    ];
  } catch (_) {
    return const [];
  }
}
```

## discover2.dart

```dart
// [SPIKE-a3f1-c] 定位 OpenCode Go 端点，并为 OpenRouter 选一个支持结构化输出的低价模型。
import 'dart:convert';
import 'dart:io';

const _envPath = 'D:/Workspace/PersonalStudio/loop-back/.env';

Map<String, String> loadEnv() {
  final out = <String, String>{};
  for (final raw in File(_envPath).readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final idx = line.indexOf('=');
    if (idx < 1) continue;
    var value = line.substring(idx + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    out[line.substring(0, idx).trim()] = value;
  }
  return out;
}

final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

Future<({int status, String body})> get(String url, String key) async {
  final req = await client.getUrl(Uri.parse(url));
  req.headers.set('Authorization', 'Bearer $key');
  req.headers.set('Accept', 'application/json');
  final res = await req.close().timeout(const Duration(seconds: 30));
  return (
    status: res.statusCode,
    body: await res.transform(utf8.decoder).join(),
  );
}

Future<void> main() async {
  final env = loadEnv();
  final goKey = env['OpenCode_APIKEY'] ?? '';
  final orKey = env['OpenRouter_APIKEY'] ?? '';

  print('== OpenCode Go 端点探测 ==');
  for (final path in <String>[
    '/zen/go/v1/models',
    '/inference/go/v1/models',
    '/zen/v1/models',
    '/inference/v1/models',
  ]) {
    try {
      final r = await get('https://opencode.ai$path', goKey);
      final preview = r.body.length > 160 ? '${r.body.substring(0, 160)}…' : r.body;
      print('$path -> ${r.status} ${preview.replaceAll(RegExp(r"\s+"), " ")}');
    } catch (e) {
      print('$path -> ERROR ${e.runtimeType}');
    }
  }

  print('\n== OpenCode Go 额度端点（只读，不产生推理费用）==');
  try {
    final r = await get('https://opencode.ai/zen/go/v1/usage', goKey);
    print('/zen/go/v1/usage -> ${r.status} ${r.body}');
  } catch (e) {
    print('/zen/go/v1/usage -> ERROR ${e.runtimeType}');
  }

  print('\n== OpenRouter：支持 structured_outputs 的最低价模型 ==');
  try {
    final r = await get('https://openrouter.ai/api/v1/models', orKey);
    final decoded = jsonDecode(r.body);
    final data = (decoded is Map ? decoded['data'] : null) as List? ?? const [];
    final candidates = <({String id, double prompt, double completion})>[];
    for (final item in data) {
      if (item is! Map) continue;
      final id = item['id'];
      final params = item['supported_parameters'];
      final pricing = item['pricing'];
      if (id is! String || params is! List || pricing is! Map) continue;
      if (!params.contains('structured_outputs')) continue;
      final prompt = double.tryParse('${pricing['prompt']}') ?? double.infinity;
      final completion =
          double.tryParse('${pricing['completion']}') ?? double.infinity;
      candidates.add((id: id, prompt: prompt, completion: completion));
    }
    candidates.sort((a, b) => a.prompt.compareTo(b.prompt));
    print('structured_outputs 模型数=${candidates.length}');
    for (final c in candidates.take(8)) {
      print('  ${c.id}  prompt=${c.prompt} completion=${c.completion}');
    }
  } catch (e) {
    print('OpenRouter models -> ERROR $e');
  }
  client.close(force: true);
}
```

## business.dart

```dart
// [SPIKE-a3f1-d] 业务级探针：三家供应商在 6 项学习任务上的结构化输出质量与耗时。
// 运行：dart run business.dart
// 只使用公开的示例句，不含用户数据；Key 从 .env 读取，任何输出都不打印 Key。
import 'dart:convert';
import 'dart:io';

import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/models/dictionary/dictionary_entry.dart';
import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/models/retell_review_evaluation.dart';
import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/models/sense_group_result.dart';
import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/models/sentence_ai_result.dart';
import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/utils/sense_group_validate.dart';

const _envPath = 'D:/Workspace/PersonalStudio/loop-back/.env';
const _sentence = 'I have been looking forward to this trip for months.';

Map<String, String> loadEnv() {
  final out = <String, String>{};
  for (final raw in File(_envPath).readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final idx = line.indexOf('=');
    if (idx < 1) continue;
    var v = line.substring(idx + 1).trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    out[line.substring(0, idx).trim()] = v;
  }
  return out;
}

class Target {
  const Target(this.name, this.base, this.key, this.model);
  final String name;
  final String base;
  final String key;
  final String model;
}

class Outcome {
  Outcome(this.task, this.ok, this.ms, this.note);
  final String task;
  final bool ok;
  final int ms;
  final String note;
}

Future<Map<String, dynamic>> chat(
  Target t,
  String system,
  String user, {
  int maxTokens = 500,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.postUrl(Uri.parse('${t.base}/chat/completions'));
    req.headers.set('Authorization', 'Bearer ${t.key}');
    req.headers.set('Content-Type', 'application/json');
    req.write(
      jsonEncode(<String, Object?>{
        'model': t.model,
        'temperature': 0,
        'max_tokens': maxTokens,
        'response_format': <String, Object?>{'type': 'json_object'},
        'messages': <Object?>[
          <String, Object?>{'role': 'system', 'content': system},
          <String, Object?>{'role': 'user', 'content': user},
        ],
      }),
    );
    final res = await req.close().timeout(const Duration(seconds: 90));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw StateError('HTTP ${res.statusCode}: ${_clip(body)}');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw StateError('response not an object');
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw StateError('no choices: ${_clip(body)}');
    }
    final message = (choices.first as Map)['message'];
    final content = message is Map ? message['content'] : null;
    if (content is! String || content.trim().isEmpty) {
      throw StateError('empty content: ${_clip(body)}');
    }
    final inner = jsonDecode(content);
    if (inner is! Map<String, dynamic>) {
      throw StateError('content not a JSON object: ${_clip(content)}');
    }
    return inner;
  } finally {
    client.close(force: true);
  }
}

String _clip(String s) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > 220 ? '${one.substring(0, 220)}…' : one;
}

Future<Outcome> run(
  Target t,
  String task,
  Future<void> Function() body,
) async {
  final sw = Stopwatch()..start();
  try {
    await body();
    return Outcome(task, true, sw.elapsedMilliseconds, '');
  } catch (error) {
    return Outcome(task, false, sw.elapsedMilliseconds, _clip('$error'));
  }
}

Future<List<Outcome>> probe(Target t) async {
  final out = <Outcome>[];

  out.add(await run(t, 'translate', () async {
    final json = await chat(
      t,
      'You translate English sentences into Simplified Chinese. '
      'Reply with JSON only: {"translation": string}.',
      'Sentence: $_sentence',
      maxTokens: 200,
    );
    final r = SentenceTranslation.fromJson(json);
    if (r.translation.trim().isEmpty) throw StateError('empty translation');
  }));

  out.add(await run(t, 'analyze', () async {
    final json = await chat(
      t,
      'Analyse an English sentence for a Chinese learner. Reply with JSON only: '
      '{"grammar":[{"point":string,"note":string}],'
      '"vocabulary":[{"term":string,"note":string}],'
      '"listening":[{"phrase":string,"note":string}]}',
      'Sentence: $_sentence',
      maxTokens: 600,
    );
    final r = SentenceAnalysis.fromJson(json);
    if (r.isEmpty) throw StateError('analysis isEmpty');
    if (r.grammar.isEmpty) throw StateError('grammar empty');
  }));

  out.add(await run(t, 'word', () async {
    final json = await chat(
      t,
      'Build a learner dictionary entry for an English word. Reply with JSON only: '
      '{"headword":string,"pronunciation":{"uk":string,"us":string},'
      '"meanings":[{"partOfSpeech":string,"translation":[string],'
      '"definition":string,"usageNote":string,"examples":[{"sentence":string,"translation":string}],'
      '"synonyms":[string],"antonyms":[string]}],'
      '"commonExpressions":[],"wordFamily":[],"forms":[],"etymology":string,'
      '"learnerTips":[string]}',
      'Word: trip',
      maxTokens: 600,
    );
    final r = DictionaryEntry.fromJson(json);
    if (r.isEmpty) throw StateError('dictionary isEmpty');
    if (r.meanings.isEmpty) throw StateError('meanings empty');
  }));

  out.add(await run(t, 'phrase', () async {
    final json = await chat(
      t,
      'Explain an English multi-word expression for a Chinese learner. Reply with JSON only: '
      '{"originalExpression":string,"naturalness":string,"category":string,'
      '"pronunciationTips":[string],'
      '"keyPoints":[{"point":string,"sentence":string,"translation":string}],'
      '"meanings":[{"translation":[string],"examples":[{"sentence":string,"translation":string}]}],'
      '"similarExpressions":[{"expression":string,"difference":string,"sentence":string,"translation":string}],'
      '"background":string}',
      'Expression: look forward to',
      maxTokens: 700,
    );
    final r = MultiWordDictionaryEntry.fromJson(json);
    if (r.isEmpty) throw StateError('phrase isEmpty');
  }));

  out.add(await run(t, 'sense-groups', () async {
    final json = await chat(
      t,
      'Split an English sentence into sense groups. Copy the original text exactly, '
      'including case and punctuation; every character must appear once, in order. '
      'Reply with JSON only: {"medium":[string],"fine":[string]}',
      'Sentence: $_sentence',
      maxTokens: 400,
    );
    final r = SenseGroupResult.fromJson(json);
    if (r.medium.isEmpty) throw StateError('medium empty');
    if (!validateSenseGroupChunks(r.medium, _sentence)) {
      throw StateError('medium fails conservation: ${jsonEncode(r.medium)}');
    }
    if (r.fine.isNotEmpty && !validateSenseGroupChunks(r.fine, _sentence)) {
      throw StateError('fine fails conservation: ${jsonEncode(r.fine)}');
    }
  }));

  out.add(await run(t, 'retell', () async {
    final json = await chat(
      t,
      'Evaluate a learner retelling against the original. Reply with JSON only: '
      '{"transcript":string,"summary":string,"rating":"poor|fair|good|excellent|perfect",'
      '"keyPoints":[{"keyPoint":string,"original":string,"transcript":string,'
      '"status":"covered|partial|missed|distorted|added","feedback":string}],'
      '"suggestion":string,"corrections":[{"type":"grammar|wordChoice|redundancy|phrasing|cohesion",'
      '"transcript":string,"correction":string,"explanation":string}]}',
      'Original: $_sentence\n'
          'Learner said: I look forward to this trip many months ago.',
      maxTokens: 700,
    );
    final r = RetellReviewEvaluation.fromJson(json);
    if (r.rating == null) throw StateError('rating null');
    if (r.keyPoints.isEmpty) throw StateError('keyPoints empty');
  }));

  return out;
}

/// 流式尾部形状：OpenRouter 会在 [DONE] 前多发一个 usage 分片。
Future<void> probeStreamTail(Target t) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.postUrl(Uri.parse('${t.base}/chat/completions'));
    req.headers.set('Authorization', 'Bearer ${t.key}');
    req.headers.set('Content-Type', 'application/json');
    req.write(
      jsonEncode(<String, Object?>{
        'model': t.model,
        'stream': true,
        'max_tokens': 32,
        'messages': <Object?>[
          <String, Object?>{'role': 'user', 'content': 'Say hi.'},
        ],
      }),
    );
    final res = await req.close().timeout(const Duration(seconds: 90));
    final text = await res.transform(utf8.decoder).join();
    final events = [
      for (final line in const LineSplitter().convert(text))
        if (line.startsWith('data:')) line.substring(5).trim(),
    ];
    var sawDone = false;
    var sawEmptyDeltaWithFinish = false;
    var contentChunks = 0;
    for (final e in events) {
      if (e == '[DONE]') {
        sawDone = true;
        continue;
      }
      try {
        final decoded = jsonDecode(e);
        if (decoded is! Map) continue;
        final choices = decoded['choices'];
        if (choices is! List || choices.isEmpty) {
          print('  [stream] 非空 choices 之外的帧: ${_clip(e)}');
          continue;
        }
        final c = choices.first;
        final delta = c is Map ? c['delta'] : null;
        final finish = c is Map ? c['finish_reason'] : null;
        final content = delta is Map ? delta['content'] : null;
        if (content is String && content.isNotEmpty) contentChunks++;
        if (finish != null &&
            (content == null || (content is String && content.isEmpty))) {
          sawEmptyDeltaWithFinish = true;
        }
      } catch (_) {
        print('  [stream] 无法解析的帧: ${_clip(e)}');
      }
    }
    print('  [stream] events=${events.length} contentChunks=$contentChunks '
        'sawDone=$sawDone emptyDeltaWithFinish=$sawEmptyDeltaWithFinish');
  } finally {
    client.close(force: true);
  }
}

Future<void> main() async {
  final env = loadEnv();
  final targets = <Target>[
    Target('deepseek', 'https://api.deepseek.com',
        env['DeepSeek_APIKEY'] ?? '', 'deepseek-flash'),
    Target('opencode-go', 'https://opencode.ai/inference/go/openai/v1',
        env['OpenCode_APIKEY'] ?? '', 'deepseek-v4.1-flash'),
    Target('openrouter', 'https://openrouter.ai/api/v1',
        env['OpenRouter_APIKEY'] ?? '', 'xingchen-agi/xing4.0-29b-a4f:free'),
  ];

  for (final t in targets) {
    print('\n===== ${t.name} / ${t.model} =====');
    final results = await probe(t);
    var ok = 0;
    for (final r in results) {
      if (r.ok) ok++;
      print('${r.ok ? 'PASS' : 'FAIL'}  ${r.task.padRight(12)} ${r.ms}ms '
          '${r.note}');
    }
    print('-- ${t.name}: $ok/${results.length} pass');
    try {
      await probeStreamTail(t);
    } catch (e) {
      print('  [stream] ERROR ${_clip('$e')}');
    }
  }
}
```

## business2.dart

```dart
// [SPIKE-a3f1-e] 业务探针 v2：修正三处真实协议差异后重跑。
// 修正点：DeepSeek 关闭默认 thinking；Go 使用真实客户端名与稳定会话头；
// OpenRouter 从目录中选择低价付费模型。只打印白名单元数据，不保存原始账户响应。
// 运行：dart run business2.dart；失败返回非零；每项一次，无自动重试。
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/models/dictionary/dictionary_entry.dart';
import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/models/retell_review_evaluation.dart';
import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/models/sense_group_result.dart';
import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/models/sentence_ai_result.dart';
import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/utils/sense_group_validate.dart';

const _envPath = 'D:/Workspace/PersonalStudio/loop-back/.env';
const _sentence = 'I have been looking forward to this trip for months.';

Map<String, String> loadEnv() {
  final out = <String, String>{};
  for (final raw in File(_envPath).readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final idx = line.indexOf('=');
    if (idx < 1) continue;
    var v = line.substring(idx + 1).trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    out[line.substring(0, idx).trim()] = v;
  }
  return out;
}

String uuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int s, int e) =>
      b.sublist(s, e).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
}

class Target {
  Target(this.name, this.base, this.key, this.model, {this.session});
  final String name;
  final String base;
  final String key;
  final String model;
  final bool? session;
  final String sessionId = uuid();
}

class ChatResult {
  ChatResult(this.json, this.finishReason, this.usage, this.ms, this.contentLen);
  final Map<String, dynamic> json;
  final String finishReason;
  final String usage;
  final int ms;
  final int contentLen;
}

final _client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

Future<ChatResult> chat(
  Target t,
  String system,
  String user, {
  int maxTokens = 3000,
}) async {
  final sw = Stopwatch()..start();
  final req = await _client.postUrl(Uri.parse('${t.base}/chat/completions'));
  req.headers.set('Authorization', 'Bearer ${t.key}');
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('User-Agent', 'EchoLoop-feasibility-spike/0.1');
  if (t.session == true) req.headers.set('x-opencode-session', t.sessionId);
  req.write(
    jsonEncode(<String, Object?>{
      'model': t.model,
      'temperature': 0,
      'max_tokens': maxTokens,
      'response_format': <String, Object?>{'type': 'json_object'},
      if (t.name == 'deepseek') 'thinking': <String, Object?>{'type': 'disabled'},
      'messages': <Object?>[
        <String, Object?>{'role': 'system', 'content': system},
        <String, Object?>{'role': 'user', 'content': user},
      ],
    }),
  );
  final res = await req.close().timeout(const Duration(seconds: 120));
  final body = await res.transform(utf8.decoder).join();
  sw.stop();
  if (res.statusCode != 200) {
    throw StateError('HTTP ${res.statusCode} code=${_errorCode(body)}');
  }
  final decoded = jsonDecode(body);
  if (decoded is! Map) throw StateError('not an object');
  final choices = decoded['choices'];
  if (choices is! List || choices.isEmpty) {
    throw StateError('no choices: ${_clip(body)}');
  }
  final choice = choices.first as Map;
  final message = choice['message'];
  final content = message is Map ? message['content'] : null;
  final finish = '${choice['finish_reason']}';
  final usage = _safeUsage(decoded['usage']);
  print('  response finish=$finish usage=$usage');
  if (finish != 'stop') throw StateError('incomplete finish=$finish');
  if (content is! String || content.trim().isEmpty) {
    throw StateError('empty content finish=$finish usage=$usage');
  }
  final inner = jsonDecode(content);
  if (inner is! Map<String, dynamic>) {
    throw StateError('content not object: ${_clip(content)}');
  }
  return ChatResult(inner, finish, usage, sw.elapsedMilliseconds, content.length);
}

String _errorCode(String body) {
  try {
    final json = jsonDecode(body);
    final error = json is Map ? json['error'] : null;
    return error is Map ? '${error['code'] ?? error['type'] ?? 'unspecified'}' : 'unspecified';
  } catch (_) { return 'non-json'; }
}

String _safeUsage(Object? value) {
  if (value is! Map) return 'unknown';
  return jsonEncode({for (final k in ['prompt_tokens','completion_tokens','total_tokens'])
    if (value[k] is num) k: value[k]});
}

int failures = 0;
String _clip(String s) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > 200 ? '${one.substring(0, 200)}…' : one;
}

Future<void> step(
  String task,
  Future<String> Function() body,
) async {
  final sw = Stopwatch()..start();
  try {
    final note = await body();
    print('PASS  ${task.padRight(12)} ${sw.elapsedMilliseconds}ms $note');
  } catch (e) {
    failures++;
    print('FAIL  ${task.padRight(12)} ${sw.elapsedMilliseconds}ms ${_clip('$e')}');
  }
}

Future<void> probe(Target t) async {
  await step('translate', () async {
    final r = await chat(
      t,
      'Translate English to Simplified Chinese. JSON only: {"translation": string}.',
      'Sentence: $_sentence',
      maxTokens: 1200,
    );
    final v = SentenceTranslation.fromJson(r.json);
    if (v.translation.trim().isEmpty) throw StateError('empty translation');
    return 'chars=${v.translation.length} finish=${r.finishReason}';
  });

  await step('analyze', () async {
    final r = await chat(
      t,
      'Analyse an English sentence for a Chinese learner. JSON only: '
      '{"grammar":[{"point":string,"note":string}],'
      '"vocabulary":[{"term":string,"note":string}],'
      '"listening":[{"phrase":string,"note":string}]}',
      'Sentence: $_sentence',
    );
    final v = SentenceAnalysis.fromJson(r.json);
    if (v.grammar.isEmpty || v.grammar.any((g) => g.point.trim().isEmpty || g.note.trim().isEmpty)
        || v.listening.isEmpty || v.listening.any((l) => l.phrase.trim().isEmpty || l.note.trim().isEmpty)
        || v.vocabulary.any((v) => v.term.trim().isEmpty || v.note.trim().isEmpty)) {
      throw StateError('missing analysis fields');
    }
    return 'grammar=${v.grammar.length} vocab=${v.vocabulary.length} '
        'listen=${v.listening.length} finish=${r.finishReason}';
  });

  await step('word', () async {
    final r = await chat(
      t,
      'Learner dictionary entry for an English word. JSON only: '
      '{"headword":string,"pronunciation":{"uk":string,"us":string},'
      '"meanings":[{"partOfSpeech":string,"translation":[string],"definition":string,'
      '"usageNote":string,"examples":[{"sentence":string,"translation":string}],'
      '"synonyms":[string],"antonyms":[string]}],'
      '"commonExpressions":[],"wordFamily":[],"forms":[],"etymology":string,'
      '"learnerTips":[string]}',
      'Word: trip',
    );
    final v = DictionaryEntry.fromJson(r.json);
    if (v.isEmpty) throw StateError('isEmpty');
    if (v.headword.toLowerCase() != 'trip' || v.meanings.isEmpty || v.meanings.any((m) =>
      m.partOfSpeech.trim().isEmpty || m.translation.isEmpty || m.definition.trim().isEmpty)) {
      throw StateError('missing word meaning');
    }
    return 'meanings=${v.meanings.length} finish=${r.finishReason}';
  });

  await step('phrase', () async {
    final r = await chat(
      t,
      'Explain an English multi-word expression for a Chinese learner. JSON only: '
      '{"originalExpression":string,"naturalness":string,"category":string,'
      '"pronunciationTips":[string],'
      '"keyPoints":[{"point":string,"sentence":string,"translation":string}],'
      '"meanings":[{"translation":[string],"examples":[{"sentence":string,"translation":string}]}],'
      '"similarExpressions":[{"expression":string,"difference":string,"sentence":string,"translation":string}],'
      '"background":string}',
      'Expression: look forward to',
    );
    final v = MultiWordDictionaryEntry.fromJson(r.json);
    if (v.originalExpression.toLowerCase() != 'look forward to' || v.category.trim().isEmpty
        || v.keyPoints.isEmpty || v.keyPoints.any((p) => p.point.trim().isEmpty)
        || v.meanings.isEmpty || v.meanings.any((m) => m.translation.isEmpty)) {
      throw StateError('missing phrase meaning');
    }
    return 'keyPoints=${v.keyPoints.length} meanings=${v.meanings.length} '
        'finish=${r.finishReason}';
  });

  await step('sense-groups', () async {
    final r = await chat(
      t,
      'Split an English sentence into sense groups. Copy the original exactly '
      '(same case and punctuation); every character must appear once, in order. '
      'JSON only: {"medium":[string],"fine":[string]}',
      'Sentence: $_sentence',
      maxTokens: 1500,
    );
    final v = SenseGroupResult.fromJson(r.json);
    if (v.medium.isEmpty) throw StateError('medium empty');
    if (!validateSenseGroupChunks(v.medium, _sentence)) {
      throw StateError('medium fails conservation: ${jsonEncode(v.medium)}');
    }
    if (v.fine.isEmpty || !validateSenseGroupChunks(v.fine, _sentence)) {
      throw StateError('fine fails conservation: ${jsonEncode(v.fine)}');
    }
    return 'medium=${v.medium.length} fine=${v.fine.length} '
        'finish=${r.finishReason}';
  });

  await step('retell', () async {
    final r = await chat(
      t,
      'Evaluate a learner retelling against the original. JSON only: '
      '{"transcript":string,"summary":string,'
      '"rating":"poor|fair|good|excellent|perfect",'
      '"keyPoints":[{"keyPoint":string,"original":string,"transcript":string,'
      '"status":"covered|partial|missed|distorted|added","feedback":string}],'
      '"suggestion":string,'
      '"corrections":[{"type":"grammar|wordChoice|redundancy|phrasing|cohesion",'
      '"transcript":string,"correction":string,"explanation":string}]}',
      'Original: $_sentence\n'
          'Learner said: I look forward to this trip many months ago.',
    );
    final v = RetellReviewEvaluation.fromJson(r.json);
    if (v.rating == null) throw StateError('rating null');
    if (v.summary.trim().isEmpty || v.keyPoints.isEmpty || v.keyPoints.any((p) =>
      p.keyPoint.trim().isEmpty || p.status == null) || v.corrections.any((c) =>
      c.type == null || c.transcript.trim().isEmpty || c.correction.trim().isEmpty)) {
      throw StateError('missing retell fields or invalid enum');
    }
    return 'rating=${v.rating!.name} keyPoints=${v.keyPoints.length} '
        'finish=${r.finishReason}';
  });
}

Future<String> pickOpenRouterModel(String key) async {
  final req = await _client.getUrl(Uri.parse('https://openrouter.ai/api/v1/models'));
  req.headers.set('Authorization', 'Bearer $key');
  final res = await req.close();
  final body = await res.transform(utf8.decoder).join();
  final data = ((jsonDecode(body) as Map)['data'] as List);
  final candidates = <({String id, double price})>[];
  for (final item in data) {
    if (item is! Map) continue;
    final id = item['id'];
    final params = item['supported_parameters'];
    final pricing = item['pricing'];
    if (id is! String || params is! List || pricing is! Map) continue;
    if (!params.contains('structured_outputs')) continue;
    final p = double.tryParse('${pricing['prompt']}') ?? -1;
    final c = double.tryParse('${pricing['completion']}') ?? -1;
    if (p <= 0 || c <= 0 || p > 0.000001 || c > 0.000001) continue;
    candidates.add((id: id, price: p + c));
  }
  candidates.sort((a, b) => a.price.compareTo(b.price));
  if (candidates.isEmpty) throw StateError('no paid structured model');
  print('  chosen=${candidates.first.id} price=${candidates.first.price}');
  return candidates.first.id;
}

/// 消费真实 SSE，记录正文首帧、尾帧与总耗时；不打印正文或推理内容。
Future<String> stream(Target t) async {
  final sw = Stopwatch()..start();
  final req = await _client.postUrl(Uri.parse('${t.base}/chat/completions'));
  req.headers.set('Authorization', 'Bearer ${t.key}');
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('User-Agent', 'EchoLoop-feasibility-spike/0.1');
  if (t.session == true) req.headers.set('x-opencode-session', t.sessionId);
  req.write(jsonEncode({
    'model':t.model, 'stream':true, 'max_tokens':1200,
    'stream_options':{'include_usage':true},
    if (t.name == 'deepseek') 'thinking':{'type':'disabled'},
    'messages':[{'role':'user','content':'Say hi in one short English sentence.'}]
  }));
  final res = await req.close().timeout(const Duration(seconds:120));
  if (res.statusCode != 200) {
    final body = await res.transform(utf8.decoder).join();
    throw StateError('HTTP ${res.statusCode} code=${_errorCode(body)}');
  }
  int? firstMs;
  var done = false, stop = false;
  var contentChunks = 0, usageFrames = 0, emptyChoices = 0, emptyFinish = 0;
  final lines = res.transform(utf8.decoder).transform(const LineSplitter());
  final data = <String>[];
  void consume() {
    if (data.isEmpty) return;
    final payload = data.join('\n');
    data.clear();
    if (payload == '[DONE]') { done = true; return; }
    final decoded = jsonDecode(payload);
    if (decoded is! Map) throw StateError('SSE not object');
    if (decoded['error'] != null) throw StateError('SSE error');
    if (decoded['usage'] is Map) usageFrames++;
    final choices = decoded['choices'];
    if (choices is! List) throw StateError('SSE missing choices');
    if (choices.isEmpty) { emptyChoices++; return; }
    for (final choice in choices.whereType<Map>()) {
      final delta = choice['delta'];
      final text = delta is Map ? delta['content'] : null;
      if (text is String && text.isNotEmpty) {
        firstMs ??= sw.elapsedMilliseconds; contentChunks++;
      }
      if (choice['finish_reason'] != null) {
        if (choice['finish_reason'] == 'stop') stop = true;
        if (text == null || text == '') emptyFinish++;
      }
    }
  }
  await (() async {
    await for (final line in lines) {
      if (line.isEmpty) consume();
      else if (line.startsWith('data:')) data.add(line.substring(5).trimLeft());
    }
    consume();
  })().timeout(const Duration(seconds:120));
  if (!done || !stop || contentChunks == 0) {
    throw StateError('incomplete SSE done=$done stop=$stop chunks=$contentChunks');
  }
  return 'firstContentMs=$firstMs totalMs=${sw.elapsedMilliseconds} '
      'chunks=$contentChunks usageFrames=$usageFrames emptyChoices=$emptyChoices '
      'emptyFinish=$emptyFinish done=$done';
}

Future<void> main() async {
  final env = loadEnv();
  final orKey = env['OpenRouter_APIKEY'] ?? '';

  final targets = <Target>[
    Target('deepseek', 'https://api.deepseek.com',
        env['DeepSeek_APIKEY'] ?? '', 'deepseek-flash'),
    Target('opencode-go', 'https://opencode.ai/inference/go/openai/v1',
        env['OpenCode_APIKEY'] ?? '', 'deepseek-v4.1-flash', session: true),
    Target('openrouter', 'https://openrouter.ai/api/v1', orKey,
        await pickOpenRouterModel(orKey)),
  ];

  for (final t in targets) {
    print('\n===== ${t.name} / ${t.model} =====');
    await probe(t);
    await step('SSE', () => stream(t));
  }
  _client.close(force: true);
  print('failures=$failures');
  if (failures > 0) exitCode = 1;
}
```

## usage.dart

```dart
// [SPIKE-a3f1-e] 真实账户接口：只输出权限、形状与可解析性，不输出金额或标识。
// 运行：dart run usage.dart；同目录 business2.dart 提供 .env 读取。
import 'dart:convert';
import 'dart:io';
import 'business2.dart' as probe;

Future<void> main() async {
  final env = probe.loadEnv();
  final client = HttpClient()..connectionTimeout = const Duration(seconds:20);
  final targets = [
    ('deepseek-balance','https://api.deepseek.com/user/balance','DeepSeek_APIKEY'),
    ('openrouter-credits','https://openrouter.ai/api/v1/credits','OpenRouter_APIKEY'),
    ('openrouter-key','https://openrouter.ai/api/v1/key','OpenRouter_APIKEY'),
    ('opencode-usage','https://opencode.ai/zen/go/v1/usage','OpenCode_APIKEY'),
  ];
  try {
    for (final (name,url,keyName) in targets) {
      try {
        final key = env[keyName];
        if (key == null || key.isEmpty) throw StateError('missing $keyName');
        final req = await client.getUrl(Uri.parse(url));
        req.followRedirects = false;
        req.headers.set('Authorization','Bearer $key');
        req.headers.set('Accept','application/json');
        req.headers.set('User-Agent','EchoLoop-feasibility-spike/0.1');
        final res = await req.close().timeout(const Duration(seconds:30));
        final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds:30));
        if (res.statusCode != 200) {
          print('$name http=${res.statusCode}'); continue;
        }
        final json = jsonDecode(body);
        if (json is! Map) throw StateError('not object');
        if (name == 'deepseek-balance') {
          final rows = json['balance_infos'];
          if (rows is! List || rows.isEmpty) throw StateError('missing balance_infos');
          for (final row in rows) {
            if (row is! Map || row['currency'] is! String) throw StateError('missing currency');
            for (final field in ['total_balance','granted_balance','topped_up_balance']) {
              if (double.tryParse('${row[field]}') case final amount? when amount.isFinite) {
                continue;
              }
              throw StateError('invalid $field');
            }
          }
          print('$name http=200 currencies=${rows.length} amountsParse=true availabilityBool=${json['is_available'] is bool}');
        } else if (name == 'openrouter-credits') {
          final data = json['data'];
          if (data is! Map || data['total_credits'] is! num || data['total_usage'] is! num) {
            throw StateError('invalid credits shape');
          }
          print('$name http=200 creditsAndUsageNumeric=true');
        } else if (name == 'openrouter-key') {
          final data = json['data'];
          if (data is! Map) throw StateError('missing data');
          print('$name http=200 budgetRemaining=${data['limit_remaining'] == null ? 'null' : data['limit_remaining'] is num ? 'numeric' : 'invalid'} '
              'limit=${data['limit'] == null ? 'null' : 'present'} reset=${data['limit_reset'] == null ? 'null' : 'present'} '
              'effectiveBudget=${data['effective_budget'] is Map}');
        } else {
          final usage = json['usage'];
          if (usage is! Map) throw StateError('missing usage');
          for (final name in ['rolling','weekly','monthly']) {
            final row = usage[name];
            if (row is! Map || row['status'] is! String || row['percent'] is! num
                || DateTime.tryParse('${row['resetsAt']}') == null) {
              throw StateError('invalid $name');
            }
          }
          print('$name http=200 windows=3 allFieldsValid=true');
        }
      } catch (e) {
        print('$name ERROR ${e.runtimeType}'); exitCode = 1;
      }
    }
  } finally { client.close(force:true); }
}
```

## contrast.dart

```dart
// [SPIKE-a3f1-f] 两项本地类型边界 + 一次 OpenRouter 严格 Schema 对照；不重跑全矩阵。
// 与 v2 相同的模型/输入/max_tokens，仅改 response_format 与 require_parameters。
import 'dart:convert';
import 'dart:io';
import 'business2.dart' as probe;
import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/models/sense_group_result.dart';
import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/utils/sense_group_validate.dart';

const sentence = 'I have been looking forward to this trip for months.';

Future<void> main() async {
  // 精确界定前次报告的范围：空对象可解析不代表任意字段类型可解析。
  for (final field in ['medium', 'fine']) {
    var rejected = false;
    try { SenseGroupResult.fromJson({field:'not-a-list'}); }
    on TypeError { rejected = true; }
    if (!rejected) throw StateError('expected TypeError for $field');
    print('LOCAL $field=String throws TypeError=true');
  }
  final key = probe.loadEnv()['OpenRouter_APIKEY'];
  if (key == null || key.isEmpty) throw StateError('missing OpenRouter_APIKEY');
  final client = HttpClient()..connectionTimeout = const Duration(seconds:20);
  final watch = Stopwatch()..start();
  try {
    await (() async {
      final req = await client.postUrl(Uri.parse('https://openrouter.ai/api/v1/chat/completions'));
      req.followRedirects = false;
      req.headers.set('Authorization','Bearer $key');
      req.headers.set('Content-Type','application/json');
      req.headers.set('User-Agent','EchoLoop-feasibility-spike/0.1');
      req.write(jsonEncode({
        'model':'mistralai/mistral-nemo', 'temperature':0, 'max_tokens':1500,
        'provider':{'require_parameters':true},
        'response_format':{'type':'json_schema','json_schema':{
          'name':'sense_groups','strict':true,'schema':{
            'type':'object','additionalProperties':false,
            'required':['medium','fine'],
            'properties':{
              'medium':{'type':'array','items':{'type':'string'}},
              'fine':{'type':'array','items':{'type':'string'}}
            }
          }
        }},
        'messages':[
          {'role':'system','content':'Split an English sentence into sense groups. Copy the original exactly '
              '(same case and punctuation); every character must appear once, in order. '
              'JSON only: {"medium":[string],"fine":[string]}'},
          {'role':'user','content':'Sentence: $sentence'}
        ]
      }));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      print('SCHEMA http=${res.statusCode} ms=${watch.elapsedMilliseconds}');
      if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
      final outer = jsonDecode(body);
      if (outer is! Map || outer['choices'] is! List) throw StateError('invalid envelope');
      final choices = outer['choices'] as List;
      if (choices.isEmpty || choices.first is! Map) throw StateError('empty choices');
      final choice = choices.first as Map;
      if (choice['finish_reason'] != 'stop') throw StateError('incomplete finish');
      final message = choice['message'];
      if (message is! Map || message['content'] is! String) throw StateError('missing content');
      final json = jsonDecode(message['content'] as String);
      if (json is! Map<String,dynamic>) throw StateError('not object');
      for (final field in ['medium','fine']) {
        final value = json[field];
        if (value is! List || value.isEmpty || value.any((x) => x is! String)) {
          throw StateError('invalid $field type');
        }
      }
      final result = SenseGroupResult.fromJson(json);
      if (!validateSenseGroupChunks(result.medium,sentence)
          || !validateSenseGroupChunks(result.fine,sentence)) throw StateError('not conserved');
      print('SCHEMA PASS finish=stop medium=${result.medium.length} fine=${result.fine.length} '
          'conserved=true totalMs=${watch.elapsedMilliseconds}');
    })().timeout(const Duration(seconds:120));
  } catch (error) {
    print('SCHEMA FAIL ${error.runtimeType} totalMs=${watch.elapsedMilliseconds}');
    exitCode = 1;
  } finally { client.close(force:true); }
}
```

## android/ProbeActivity.java

```java
// [SPIKE-a3f1-e] 独立 SAF 探针：只接受合成目录，不申请存储或网络权限。
package dev.echoloop.spike.a3f1;

import android.app.Activity;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.provider.DocumentsContract;
import android.util.Log;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;

public class ProbeActivity extends Activity {
    private static final String TAG = "EchoLoopSpike_a3f1";
    private static final String TREE = "primary:Download/EchoLoopSpike_a3f1";
    private TextView output;

    private void record(String value) {
        Log.i(TAG, value);
        output.append(value + "\n");
    }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        output = new TextView(this);
        Button pick = new Button(this);
        pick.setText("Pick synthetic test folder");
        pick.setOnClickListener(v -> {
            Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
                | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
            intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI,
                Uri.parse("content://com.android.externalstorage.documents/document/primary%3ADownload%2FEchoLoopSpike_a3f1"));
            startActivityForResult(intent, 41);
        });
        layout.addView(pick);
        layout.addView(output);
        setContentView(layout);
        if (getIntent().getBooleanExtra("check", false)) {
            String saved = getPreferences(MODE_PRIVATE).getString("tree", null);
            if (saved == null) record("FAIL missing saved tree");
            else verify(Uri.parse(saved), "persisted");
        }
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != 41) return;
        if (result != RESULT_OK || data == null || data.getData() == null) {
            record("CANCELLED no read attempted");
            return;
        }
        Uri tree = data.getData();
        // 信任边界：只读本次造出的目录，误选不遍历、也不持久化授权。
        if (!TREE.equals(DocumentsContract.getTreeDocumentId(tree))) {
            record("FAIL wrong directory refused");
            return;
        }
        try {
            int flags = data.getFlags() & Intent.FLAG_GRANT_READ_URI_PERMISSION;
            getContentResolver().takePersistableUriPermission(tree, flags);
            getPreferences(MODE_PRIVATE).edit().putString("tree", tree.toString()).commit();
            verify(tree, "picked");
        } catch (Exception error) {
            record("FAIL " + error.getClass().getSimpleName());
        }
    }

    // 用平台 DocumentsContract 遍历直接子项，通过流复制到本探针缓存并计算指纹。
    private void verify(Uri tree, String phase) {
        try {
            if (!TREE.equals(DocumentsContract.getTreeDocumentId(tree))) {
                throw new SecurityException("unexpected saved tree");
            }
            boolean persisted = false;
            for (android.content.UriPermission permission : getContentResolver().getPersistedUriPermissions()) {
                if (permission.getUri().equals(tree) && permission.isReadPermission()) persisted = true;
            }
            if (!persisted) throw new SecurityException("no persisted grant");
            Uri children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, TREE);
            String[] projection = {
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE
            };
            ArrayList<String> records = new ArrayList<>();
            int directories = 0;
            try (Cursor cursor = getContentResolver().query(children, projection, null, null, null)) {
                if (cursor == null) throw new IllegalStateException("null cursor");
                while (cursor.moveToNext()) {
                    if (DocumentsContract.Document.MIME_TYPE_DIR.equals(cursor.getString(2))) {
                        directories++;
                        continue;
                    }
                    String name = cursor.getString(1);
                    if (name == null || name.contains("/") || name.contains("\\")
                        || name.equals(".") || name.equals("..")) throw new SecurityException("invalid name");
                    Uri document = DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0));
                    MessageDigest hash = MessageDigest.getInstance("SHA-256");
                    long bytes = 0;
                    try (InputStream in = getContentResolver().openInputStream(document);
                         FileOutputStream out = new FileOutputStream(new File(getCacheDir(), name))) {
                        if (in == null) throw new IllegalStateException("null stream");
                        byte[] buffer = new byte[4096];
                        int count;
                        while ((count = in.read(buffer)) != -1) {
                            hash.update(buffer, 0, count);
                            out.write(buffer, 0, count);
                            bytes += count;
                        }
                    }
                    if (!cursor.isNull(3) && cursor.getLong(3) != bytes) {
                        throw new IllegalStateException("size mismatch");
                    }
                    StringBuilder digest = new StringBuilder();
                    for (byte b : hash.digest()) digest.append(String.format("%02x", b & 255));
                    records.add("FILE " + name + " bytes=" + bytes + " sha256=" + digest);
                }
            }
            Collections.sort(records);
            record("PHASE " + phase + " persisted=true files=" + records.size() + " directories=" + directories);
            for (String row : records) record(row);
            record("END " + phase);
        } catch (Exception error) {
            record("FAIL " + phase + " " + error.getClass().getSimpleName());
        }
    }
}
```

## android/AndroidManifest.xml

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="dev.echoloop.spike.a3f1">
  <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="28" />
  <application android:label="EchoLoop SAF spike" android:debuggable="true" android:theme="@android:style/Theme.Material.Light.NoActionBar">
    <activity android:name=".ProbeActivity" android:exported="true" />
  </application>
</manifest>
```

## android/fixture.ps1

合成文件复建脚本；本轮原始文件通过 adb shell printf 创建，以上脚本以相同 UTF-8 字节重建。01.srt 为 45 bytes，02.vtt 为 32 bytes，不含 BOM；扩展名不表示音频可解码。

```powershell
# [SPIKE-a3f1-e] 精确复建本次字节 fixture；若目标目录存在则拒绝覆盖。
$ErrorActionPreference = 'Stop'
$taskDevice = 'aaf0c82b' # 替换为 adb devices 中本次授权设备
$taskRemote = '/sdcard/Download/EchoLoopSpike_a3f1'
adb -s $taskDevice shell "[ ! -e $taskRemote ]"
if ($LASTEXITCODE -ne 0) { throw 'Fixture directory already exists; do not overwrite' }
$taskLocal = Join-Path $PSScriptRoot 'fixture'
New-Item -ItemType Directory -Force -Path "$taskLocal/sub" | Out-Null
$taskUtf8 = New-Object System.Text.UTF8Encoding($false)
$taskFiles = [ordered]@{
  '01.mp3' = 'synthetic-audio-one-0123456789'
  '01.srt' = "1`n00:00:00,000 --> 00:00:02,000`nHello there.`n"
  '02.MP3' = 'synthetic-audio-two-abcdef'
  '02.vtt' = "WEBVTT`n`n00:00 --> 00:02`nSecond.`n"
  'notes.txt' = 'ignored'
  'sub/inner.mp3' = 'nested'
}
foreach ($taskEntry in $taskFiles.GetEnumerator()) {
  [IO.File]::WriteAllText((Join-Path $taskLocal $taskEntry.Key), $taskEntry.Value, $taskUtf8)
}
adb -s $taskDevice push $taskLocal $taskRemote
if ($LASTEXITCODE -ne 0) { throw 'Fixture push failed' }
Get-ChildItem $taskLocal -File -Recurse | ForEach-Object {
  '{0} bytes={1} sha256={2}' -f $_.Name, $_.Length, (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
```

## Android 复现步骤与当前边界

```powershell
Set-Location (Join-Path $env:TEMP 'echo-loop-spike-a3f1/android')
./build.ps1
./fixture.ps1
adb -s aaf0c82b install -r ./probe.apk
# 仅在设备允许安装后继续；不要修改设备安全策略绕过拦截。
adb -s aaf0c82b shell am start -n dev.echoloop.spike.a3f1/.ProbeActivity
# 点 Pick synthetic test folder，选择 Download/EchoLoopSpike_a3f1。
adb -s aaf0c82b logcat -d -s EchoLoopSpike_a3f1:I '*:S'
adb -s aaf0c82b shell am force-stop dev.echoloop.spike.a3f1
adb -s aaf0c82b shell am start -n dev.echoloop.spike.a3f1/.ProbeActivity --ez check true
adb -s aaf0c82b logcat -d -s EchoLoopSpike_a3f1:I '*:S'
```

通过条件：picked / persisted 都输出 files=5、directories=1，逐项 SHA-256 与 fixture 一致，无 FAIL。下面是主机根据确定输入算出的期望值，**不是 Android 读取实测结果**：

| 文件 | bytes | SHA-256 |
| --- | --- | --- |
| 01.mp3 | 30 | c19e23aa122e2a69acaf31fb882a16939b74c7c1a851e49b0d5c2b71ed7eb524 |
| 01.srt | 45 | 490f2542b4fe9b875f80fa1c0a8dec5161da8f214f497b07f5a3ffa3fb01dfc7 |
| 02.MP3 | 26 | 3845f85a816777e82d97a17c6f55fd98ffd4ff70d40a8f88e7727ce13dce1537 |
| 02.vtt | 32 | e1dcfceb7592f776940af39adf26183f3377f2e53651d9c14b31c07aeadc7031 |
| notes.txt | 7 | 3514cf816e5407a39cb7a1c1e1243f176dda121e06398a8934edb1dc426b0b34 |
| sub/inner.mp3（不递归读取） | 6 | 233562de1a0288b139c4fa40b7d189f806e906eeb048517aeb67f34ac0e2faf1 |

拒绝误选、取消操作、空目录、现代 Android 和其他 document provider 尚需另行实际运行，不能用本 APK 的逻辑当作已通过证据。本轮停于 USB 安装被 MIUI 拦截；上面的启动及重启步骤尚未执行。

## android/build.ps1

```powershell
# [SPIKE-a3f1-e] 仅使用已安装 Android SDK / JDK；不安装依赖，不连接 Gradle。
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$taskSdk = 'D:/Application/Android/Sdk'
$taskBuild = "$taskSdk/build-tools/35.0.0"
$taskJdk = 'D:/Application/Scoop/apps/corretto17-jdk/current'
$taskAndroid = "$taskSdk/platforms/android-35/android.jar"
function Invoke-Checked([scriptblock]$action) {
  & $action
  if ($LASTEXITCODE -ne 0) { throw "Build command failed ($LASTEXITCODE)" }
}
New-Item -ItemType Directory -Path 'classes','dex' -Force | Out-Null
Invoke-Checked { & "$taskJdk/bin/javac.exe" -source 8 -target 8 -encoding UTF-8 -classpath $taskAndroid -d classes ProbeActivity.java }
Invoke-Checked { & "$taskJdk/bin/jar.exe" cf classes.jar -C classes . }
$taskPreviousJava = $env:JAVA_HOME
try {
  $env:JAVA_HOME = $taskJdk
  Invoke-Checked { & "$taskBuild/d8.bat" --lib $taskAndroid --min-api 26 --output dex classes.jar }
  Invoke-Checked { & "$taskBuild/aapt2.exe" link -I $taskAndroid --manifest AndroidManifest.xml --min-sdk-version 26 --target-sdk-version 28 -o unsigned.apk }
  $taskDexPath = (Resolve-Path dex).Path
  Invoke-Checked { & "$taskJdk/bin/jar.exe" uf unsigned.apk -C $taskDexPath classes.dex }
  Invoke-Checked { & "$taskBuild/zipalign.exe" -f 4 unsigned.apk aligned.apk }
  if (-not (Test-Path spike.keystore)) {
    Invoke-Checked { & "$taskJdk/bin/keytool.exe" -genkeypair -keystore spike.keystore -storepass android -keypass android -alias spike -keyalg RSA -validity 2 -dname 'CN=temporary synthetic spike' }
  }
  Invoke-Checked { & "$taskBuild/apksigner.bat" sign --ks spike.keystore --ks-key-alias spike --ks-pass pass:android --key-pass pass:android --out probe.apk aligned.apk }
  Invoke-Checked { & "$taskBuild/apksigner.bat" verify probe.apk }
} finally { $env:JAVA_HOME = $taskPreviousJava }
Write-Output 'BUILD PASS probe.apk'
```

## android/target36/AndroidManifest.xml

与产品 `minSdk 24 / targetSdk 36` 一致的变体（产品值来自 `android/app/build.gradle.kts` 的 `flutter.targetSdkVersion`；本机 Flutter 3.10.7 的 `FlutterExtension.targetSdkVersion = 36`）。上一节是 targetSdk 28 的版本，探针逻辑相同。

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="dev.echoloop.spike.a3f1">
  <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="36" />
  <application android:label="EchoLoop SAF spike" android:debuggable="true" android:theme="@android:style/Theme.Material.Light.NoActionBar">
    <activity android:name=".ProbeActivity" android:exported="true" />
  </application>
</manifest>
```

## android/target36/build.ps1

对应构建脚本；与上一节的差异仅为 `--min-api 24` 与 `--target-sdk-version 36`。该版本 APK 经 `aapt2 dump badging` 确认 `minSdkVersion:'24'`、`targetSdkVersion:'36'`，但**安装被 MIUI 拦截，未在设备上运行**。

```powershell
# [SPIKE-a3f1-e] 仅使用已安装 Android SDK / JDK；不安装依赖，不连接 Gradle。
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$taskSdk = 'D:/Application/Android/Sdk'
$taskBuild = "$taskSdk/build-tools/35.0.0"
$taskJdk = 'D:/Application/Scoop/apps/corretto17-jdk/current'
$taskAndroid = "$taskSdk/platforms/android-35/android.jar"
function Invoke-Checked([scriptblock]$action) {
  & $action
  if ($LASTEXITCODE -ne 0) { throw "Build command failed ($LASTEXITCODE)" }
}
New-Item -ItemType Directory -Path 'classes','dex' -Force | Out-Null
Invoke-Checked { & "$taskJdk/bin/javac.exe" -source 8 -target 8 -encoding UTF-8 -classpath $taskAndroid -d classes ProbeActivity.java }
Invoke-Checked { & "$taskJdk/bin/jar.exe" cf classes.jar -C classes . }
$taskPreviousJava = $env:JAVA_HOME
try {
  $env:JAVA_HOME = $taskJdk
  Invoke-Checked { & "$taskBuild/d8.bat" --lib $taskAndroid --min-api 24 --output dex classes.jar }
  Invoke-Checked { & "$taskBuild/aapt2.exe" link -I $taskAndroid --manifest AndroidManifest.xml --min-sdk-version 24 --target-sdk-version 36 -o unsigned.apk }
  $taskDexPath = (Resolve-Path dex).Path
  Invoke-Checked { & "$taskJdk/bin/jar.exe" uf unsigned.apk -C $taskDexPath classes.dex }
  Invoke-Checked { & "$taskBuild/zipalign.exe" -f 4 unsigned.apk aligned.apk }
  if (-not (Test-Path spike.keystore)) {
    Invoke-Checked { & "$taskJdk/bin/keytool.exe" -genkeypair -keystore spike.keystore -storepass android -keypass android -alias spike -keyalg RSA -validity 2 -dname 'CN=temporary synthetic spike' }
  }
  Invoke-Checked { & "$taskBuild/apksigner.bat" sign --ks spike.keystore --ks-key-alias spike --ks-pass pass:android --key-pass pass:android --out probe.apk aligned.apk }
  Invoke-Checked { & "$taskBuild/apksigner.bat" verify probe.apk }
} finally { $env:JAVA_HOME = $taskPreviousJava }
Write-Output 'BUILD PASS probe.apk'
```
