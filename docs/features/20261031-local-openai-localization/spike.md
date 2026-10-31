# Echo Loop 供应商迁移可行性证据

## Run: 2026-10-31 供应商接口适配与 Android 目录导入前提

### 问题与判定标准

**候选**：提案 A——Flutter 客户端直连供应商 OpenAI 兼容接口（OpenCode Go / DeepSeek / OpenRouter），并复用本机 ASR 与既有存储。

**依赖的设计选择**：是否需要自建结果校验层；意群校验能否直接复用；用量卡字段映射能否按官方示例落地；Android 目录导入是新写还是复用。

四个子问题，各自有可判定的标准：

| # | 问题 | 支持（Supported）的判定 |
| --- | --- | --- |
| Q1 | 现有 `fromJson` 能否充当「结果有效」的判定？ | 若空对象/空洞内容/类型错误都会静默成功，则**不能**单独作为有效性门禁 |
| Q2 | `validateSenseGroupChunks` 能否挡住漏词与加词？ | 漏词、加词、乱序、空列表必须被拒；精确拼接与空白/标点差异必须通过 |
| Q3 | 三家用量/余额字段映射能否从官方文档示例确定实现？ | 文档示例与边界（字符串金额、多币种、403、无预算、`percent=0`、`rate-limited`）都能得出确定展示值，且未知值不被当成 0 |
| Q4 | Android 目录导入是否已现成可用？ | 仓库已有目录选择（tree picker）且有设备可运行验证 |

**范围外**：模型在真实学习任务上的 JSON 有效性与耗时（无凭据，见「结论与限制」）；任何线上接口调用。

### 方法与条件

- 环境：Windows 10.0.26200，Dart SDK 3.10.7（stable，2025-12-23），`flutter` 3.x 随附 SDK。
- 探针：单个纯 Dart 文件，`import` 仓库真实模型与校验源码（`file:///` 绝对路径），**不含 Flutter、网络、随机数或时钟依赖**，41 项断言，失败即非零退出。
- 未读取任何 API Key 值，也未用任何凭据发起请求；曾用一条命令检查 4 个供应商 Key 环境变量是否非空，输出为空，未参与后续步骤。工作区未跟踪的 `.env` 未被读取或暂存。
- 仓库基线：`b8a06eae44d9574140e8c526e51239270a0a7d2d`（工作区仅有未跟踪 `.pi/` 与 `.env`，后者未被读取或暂存）。
- 探针位置：仓库外临时目录（`%TEMP%\echo-loop-spike-a3f1\probe.dart`），未写入产品文件。
- Q4 方法：静态检索 `ACTION_OPEN_DOCUMENT_TREE` / `DocumentFile` / `getDirectoryPath`，并执行 `adb devices -l` 检查可用设备。

复现命令：

```powershell
$dart = 'D:/Application/Scoop/apps/flutter/current/bin/cache/dart-sdk/bin/dart.exe'
Set-Location '%TEMP%\echo-loop-spike-a3f1'
& $dart run probe.dart
```

### 观察结果

#### A. `fromJson` 不是有效性门禁

- `SentenceAnalysis.fromJson({})`、`DictionaryEntry.fromJson({})`、`MultiWordDictionaryEntry.fromJson({})`、`RetellReviewEvaluation.fromJson({})`、`SenseGroupResult.fromJson({})` **全部不抛异常**，但结果分别为 `isEmpty=true`、`isEmpty=true`、`isEmpty=true`、`rating=null` 且三段皆空、两个粒度皆空。
- 结构存在但值全空（`{'grammar':[{'point':'  ','note':''}], ...}`）同样不抛，只表现为 `isEmpty=true`。
- 类型错误（`'grammar': 'not-a-list'`、`'vocabulary': 42`）也不抛，静默降级为空集合。

结论：`fromJson` 的设计目标就是「半成品快照永不抛」，因此**不能**用「解析成功」代表「结果有效」。区分有效与空洞只能靠 `isEmpty`、必填字段、枚举取值与语义校验。

#### B. 意群守恒校验可用，但比预期更严格

| 输入 | 结果 |
| --- | --- |
| 精确拼接 | 通过 |
| 去掉分隔空格 | 通过（慢路径剥空白） |
| 标点被替换（`,` `;` `!`） | 通过 |
| 漏词 | 拒绝 |
| 加词 | 拒绝 |
| 顺序调换（内容相同） | 拒绝 |
| 空列表 | 拒绝 |
| **仅大小写不同** | **拒绝** |

最后一项**证伪了本次探针的初始假设**（初版断言「大小写变化不被发现」，实际失败）。原因：`_stripWp` 只剥空白与标点，不折叠大小写，因此 `'i have been…'` 与 `'I have been…'` 不相等。

设计含义：该校验对「模型改写大小写」是零容忍的。若目标模型会把句首大写或专有名词小写化，意群结果会被判失败、不落缓存并触发重试——这是正确性优先的行为，但会增加失败率，需要在合同中明确「大小写必须原样保留」。

#### C. 用量/余额映射可确定实现

以官方文档示例为固定输入，全部得出确定结果：

- **DeepSeek**：字符串金额 `'110.00'` → `110.0`；币种 `CNY` 保留；`granted_balance` / `topped_up_balance` 保留为 `10.0` / `100.0`；多币种各自保留不混加；缺构成字段为 `null`（不填 0）；无法解析的金额被丢弃而非置 0。
- **OpenRouter `/credits`**：`100.5 - 25.75 = 74.75`；缺 `total_usage` 时拒绝出数；403 错误体不产出余额。
- **OpenRouter `/key`**：`limit_remaining=74.5` 与 `limit_reset='monthly'` 正确取出；`limit_remaining=null`（未设预算）保持 `null`，不显示 0。
- **OpenCode Go**：`rolling/weekly/monthly` 三窗口全部解析；`status='rate-limited'` 且 `percent=99` 仍被识别为已限额；`percent=0` 时丢弃占位 `resetsAt`；响应形状漂移（`rolling` 变成字符串）返回空集合而非崩溃；主标题取「已用最多」窗口。

**这是映射规格的证据，不是线上行为的证据**：输入取自官方文档示例，未验证真实 Key 的权限差异（尤其 OpenRouter `/credits` 的 Management Key 要求）。

#### D. Android 目录导入没有现成实现

- 仓库内只有 `ACTION_OPEN_DOCUMENT`（文件多选），检索 `ACTION_OPEN_DOCUMENT_TREE`、`DocumentFile`、`getDirectoryPath` 均无命中。
- 原生通道只暴露 `pickAudioFiles` / `readBytes` / `copyToFile` 三个方法，全部以 content URI 为单位。
- `adb devices -l` 无设备连接，无法做运行验证。
- 可复用的部分确实存在：`matchSubtitlesForAudios`（去扩展名同名配对，srt > vtt > lrc）与 `classifyImportFiles`（扩展名白名单）都是纯函数，可直接用于目录内批量导入。

### 结论与限制

| 问题 | 结论 | 条件与边界 |
| --- | --- | --- |
| Q1 `fromJson` 作有效性判定 | **Not supported** | 五种模型在空对象、空洞值、类型错误下全部静默成功；必须另设校验层 |
| Q2 意群守恒校验 | **Supported** | 在 41 项断言覆盖的输入上成立；额外发现：大小写差异同样被拒，属更严格而非更宽松 |
| Q3 用量/余额映射 | **Supported（仅映射规格）** | 以官方文档示例为输入成立；**不**证明线上响应、权限或字段稳定性 |
| Q4 Android 目录导入 | **Inconclusive** | 静态证据表明当前无 tree picker（实现缺口已确认）；无设备，无法验证 SAF 目录遍历与真实 provider 行为 |
| 主问题：模型结构化输出质量 | **Inconclusive** | 无可用凭据，未做任何推理调用；协议支持仅有官方文档证据 |

本次**不**建立：任何模型的 JSON 有效率、首字/总耗时、真实余额权限、目录导入的端到端可用性。

### 对设计的影响

1. **必须显式区分「解析成功」与「结果有效」**：校验层至少覆盖 `isEmpty`、必填字段、枚举取值、长度上限；意群另加守恒校验。仅靠现有 `fromJson` 会把空对象当成功并写入缓存。
2. **意群校验比预期严格**：需在合同中写明「大小写与词序必须原样保留」，否则弱模型会稳定触发重试；若产品接受归一化比较，应作为独立决定，不能靠放宽校验来掩盖。
3. **用量卡字段映射可直接实现**，但须保留三条硬规则：未知值为 `null` 而非 0、多币种不混加、`rate-limited` 优先于百分比。
4. **目录导入是新增原生能力**：需要 `ACTION_OPEN_DOCUMENT_TREE` + 子项遍历，再喂给现有 `classifyImportFiles` / `matchSubtitlesForAudios`；不能假定 `file_picker` 的目录接口在 Android 上等价可用（未验证）。
5. **剩余证据缺口**（交回 `ideate` 判断是否值得再跑）：模型级 JSON 有效性与耗时需真实 Key；OpenRouter `/credits` 的普通推理 Key 权限需实测；Android 目录导入需一台设备。

### 复现用探针（完整）

```dart
// [SPIKE-a3f1] 可行性探针：Echo Loop 供应商迁移的三条待验证前提。
//
// 运行：dart run probe.dart
// 依赖：Dart 3.10.7；只 import 仓库内纯 Dart 模型文件，不接触 Flutter、网络或真实凭据。
import 'dart:io';

import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/models/dictionary/dictionary_entry.dart';
import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/models/retell_review_evaluation.dart';
import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/models/sense_group_result.dart';
import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/models/sentence_ai_result.dart';
import 'file:///D:/Workspace/PersonalStudio/loop-back/lib/utils/sense_group_validate.dart';

int checks = 0;
int failures = 0;

void check(String name, bool ok, [Object? detail]) {
  checks++;
  if (!ok) failures++;
  final suffix = detail == null ? '' : ' -> $detail';
  print('${ok ? 'PASS' : 'FAIL'}  $name$suffix');
}

void section(String title) => print('\n== $title ==');

// ── A. fromJson 的容忍度 ────────────────────────────────────────────
void probeA() {
  section('A. fromJson 是否可充当有效性判定');

  final analysis = SentenceAnalysis.fromJson(<String, dynamic>{});
  check('SentenceAnalysis.fromJson({}) 不抛', true);
  check('  ...但 isEmpty=true（无内容）', analysis.isEmpty, analysis.toJson());

  final dict = DictionaryEntry.fromJson(<String, dynamic>{});
  check('DictionaryEntry.fromJson({}) 不抛', true);
  check('  ...但 isEmpty=true', dict.isEmpty);

  final multi = MultiWordDictionaryEntry.fromJson(<String, dynamic>{});
  check('MultiWordDictionaryEntry.fromJson({}) 不抛', true);
  check('  ...但 isEmpty=true', multi.isEmpty);

  final evaluation = RetellReviewEvaluation.fromJson(<String, dynamic>{});
  check('RetellReviewEvaluation.fromJson({}) 不抛', true);
  check(
    '  ...但 rating=null 且三段皆空（不可当有效结果）',
    evaluation.rating == null &&
        evaluation.summary.isEmpty &&
        evaluation.keyPoints.isEmpty &&
        evaluation.corrections.isEmpty,
  );

  final sense = SenseGroupResult.fromJson(<String, dynamic>{});
  check('SenseGroupResult.fromJson({}) 不抛', true);
  check(
    '  ...但两个粒度都为空',
    sense.medium.isEmpty && sense.fine.isEmpty,
  );

  final hollow = SentenceAnalysis.fromJson(<String, dynamic>{
    'grammar': [
      <String, dynamic>{'point': '  ', 'note': ''},
    ],
    'vocabulary': <dynamic>[],
    'listening': <dynamic>[],
  });
  check('空字符串要点不抛', true);
  check('  ...但 isEmpty=true（需 isEmpty 才能识别）', hollow.isEmpty);

  final wrongType = SentenceAnalysis.fromJson(<String, dynamic>{
    'grammar': 'not-a-list',
    'vocabulary': 42,
  });
  check('类型错误不抛、静默降级为空', wrongType.isEmpty);
}

// ── B. 意群守恒校验 ────────────────────────────────────────────────
void probeB() {
  section('B. validateSenseGroupChunks 的判定边界');

  const original = 'I have been looking forward to this trip for months.';

  final exact = <String>[
    'I have been looking ',
    'forward to this trip ',
    'for months.',
  ];
  check('精确拼接通过', validateSenseGroupChunks(exact, original));

  final spaced = <String>[
    'I have been looking',
    'forward to this trip',
    'for months.',
  ];
  check('丢空格仍通过（慢路径）', validateSenseGroupChunks(spaced, original));

  final repunct = <String>[
    'I have been looking, ',
    'forward to this trip; ',
    'for months!',
  ];
  check('换标点仍通过（慢路径）', validateSenseGroupChunks(repunct, original));

  final dropped = <String>[
    'I have been looking ',
    'forward to this trip.',
  ];
  check('漏词被拒绝', !validateSenseGroupChunks(dropped, original));

  final added = <String>[
    'I have been looking ',
    'forward to this trip ',
    'for months and months.',
  ];
  check('加词被拒绝', !validateSenseGroupChunks(added, original));

  final reordered = <String>[
    'forward to this trip ',
    'I have been looking ',
    'for months.',
  ];
  check('乱序被拒绝（内容相同但顺序变）', !validateSenseGroupChunks(reordered, original));

  check('空列表被拒绝', !validateSenseGroupChunks(const <String>[], original));

  // 实测修正：stripWp 不去大小写，因此仅大小写差异也会被拒。
  // 初版假设“大小写变化不被发现”已被证伪。
  final cased = <String>[
    'i have been looking ',
    'forward to this trip ',
    'for months.',
  ];
  check(
    '大小写变化也被拒绝（比初版假设更严格）',
    !validateSenseGroupChunks(cased, original),
  );
}

// ── C. 用量/余额字段映射 ────────────────────────────────────────────
class Amount {
  const Amount(this.currency, this.total, this.granted, this.toppedUp);
  final String currency;
  final double total;
  final double? granted;
  final double? toppedUp;
}

/// DeepSeek `/user/balance`：金额是字符串，可能多币种。
List<Amount> parseDeepSeekBalance(Map<String, Object?> body) {
  final raw = body['balance_infos'];
  if (raw is! List) return const <Amount>[];
  final out = <Amount>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final total = _num(item['total_balance']);
    final currency = item['currency'];
    if (total == null || currency is! String || currency.isEmpty) continue;
    out.add(
      Amount(
        currency.toUpperCase(),
        total,
        _num(item['granted_balance']),
        _num(item['topped_up_balance']),
      ),
    );
  }
  return out;
}

/// OpenRouter `/credits`：账户级，需 Management Key。
double? parseOpenRouterCredits(Map<String, Object?> body) {
  final data = body['data'];
  if (data is! Map) return null;
  final total = _num(data['total_credits']);
  final used = _num(data['total_usage']);
  if (total == null || used == null) return null;
  return total - used;
}

/// OpenRouter `/key`：Key 级预算余额；无预算时不应显示为 0。
({double? remaining, String? reset}) parseOpenRouterKey(
  Map<String, Object?> body,
) {
  final data = body['data'];
  if (data is! Map) return (remaining: null, reset: null);
  final reset = data['limit_reset'];
  return (
    remaining: _num(data['limit_remaining']),
    reset: reset is String && reset.isNotEmpty ? reset : null,
  );
}

class UsageWindow {
  const UsageWindow(this.name, this.usedPercent, this.resetsAt, this.status);
  final String name;
  final double usedPercent;
  final DateTime? resetsAt;
  final String status;
  bool get isLimited => status == 'rate-limited';
}

/// OpenCode Go `/zen/go/v1/usage`：percent 为 0 时 resetsAt 是占位值，需丢弃。
List<UsageWindow> parseOpenCodeUsage(Map<String, Object?> body) {
  final usage = body['usage'];
  if (usage is! Map) return const <UsageWindow>[];
  const names = <String, String>{
    'rolling': '5 hours',
    'weekly': '7 days',
    'monthly': 'Month',
  };
  final out = <UsageWindow>[];
  for (final entry in names.entries) {
    final raw = usage[entry.key];
    if (raw is! Map) continue;
    final percent = _num(raw['percent']);
    if (percent == null) continue;
    final status = raw['status'];
    DateTime? reset;
    final resetsAt = raw['resetsAt'];
    if (percent > 0 && resetsAt is String) {
      reset = DateTime.tryParse(resetsAt);
    }
    out.add(
      UsageWindow(
        entry.value,
        percent,
        reset,
        status is String ? status : 'unknown',
      ),
    );
  }
  return out;
}

double? _num(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

void probeC() {
  section('C. 用量/余额映射（官方文档示例）');

  final deepSeek = parseDeepSeekBalance(<String, Object?>{
    'is_available': true,
    'balance_infos': <Object?>[
      <String, Object?>{
        'currency': 'CNY',
        'total_balance': '110.00',
        'granted_balance': '10.00',
        'topped_up_balance': '100.00',
      },
    ],
  });
  check('DeepSeek 字符串金额可解析', deepSeek.length == 1);
  check('  币种 CNY', deepSeek.single.currency == 'CNY');
  check('  总额 110.00', deepSeek.single.total == 110.0, deepSeek.single.total);
  check(
    '  构成 10/100 保留',
    deepSeek.single.granted == 10.0 && deepSeek.single.toppedUp == 100.0,
  );

  final multiCurrency = parseDeepSeekBalance(<String, Object?>{
    'balance_infos': <Object?>[
      <String, Object?>{'currency': 'USD', 'total_balance': '5.00'},
      <String, Object?>{'currency': 'CNY', 'total_balance': '0'},
    ],
  });
  check('多币种各自保留（不混加）', multiCurrency.length == 2);
  check(
    '  缺构成字段时为 null，不填 0',
    multiCurrency.first.granted == null &&
        multiCurrency.first.toppedUp == null,
  );

  final brokenDeepSeek = parseDeepSeekBalance(<String, Object?>{
    'balance_infos': <Object?>[
      <String, Object?>{'currency': 'CNY', 'total_balance': 'n/a'},
    ],
  });
  check('无法解析的金额被丢弃而非置 0', brokenDeepSeek.isEmpty);

  final credits = parseOpenRouterCredits(<String, Object?>{
    'data': <String, Object?>{'total_credits': 100.5, 'total_usage': 25.75},
  });
  check('OpenRouter 账户余额 = 74.75', credits == 74.75, credits);

  final noUsage = parseOpenRouterCredits(<String, Object?>{
    'data': <String, Object?>{'total_credits': 100.5},
  });
  check('缺 total_usage 时拒绝出数（不猜 0）', noUsage == null);

  final forbidden = parseOpenRouterCredits(<String, Object?>{
    'error': <String, Object?>{'code': 403, 'message': 'Only management keys'},
  });
  check('403 错误体不产出余额', forbidden == null);

  final withBudget = parseOpenRouterKey(<String, Object?>{
    'data': <String, Object?>{
      'limit_remaining': 74.5,
      'limit_reset': 'monthly',
    },
  });
  check('Key 预算余额 74.5', withBudget.remaining == 74.5);
  check('  周期 monthly', withBudget.reset == 'monthly');

  final noBudget = parseOpenRouterKey(<String, Object?>{
    'data': <String, Object?>{'limit_remaining': null},
  });
  check('未设预算时 remaining=null（不显示 0）', noBudget.remaining == null);
  check('  周期缺省为 null', noBudget.reset == null);

  final go = parseOpenCodeUsage(<String, Object?>{
    'usage': <String, Object?>{
      'rolling': <String, Object?>{
        'status': 'ok',
        'percent': 37,
        'resetsAt': '2026-08-26T14:12:03.000Z',
      },
      'weekly': <String, Object?>{
        'status': 'ok',
        'percent': 3,
        'resetsAt': '2026-08-17T00:00:00.287Z',
      },
      'monthly': <String, Object?>{
        'status': 'rate-limited',
        'percent': 99,
        'resetsAt': '2026-09-13T06:06:01.287Z',
      },
    },
  });
  check('三窗口全部解析', go.length == 3, go.length);
  check('rolling=37%', go.first.usedPercent == 37);
  check(
    'rate-limited 被识别（即使 percent 向下取整到 99）',
    go.last.isLimited && go.last.usedPercent == 99,
  );

  final zero = parseOpenCodeUsage(<String, Object?>{
    'usage': <String, Object?>{
      'rolling': <String, Object?>{
        'status': 'ok',
        'percent': 0,
        'resetsAt': '2026-10-31T18:00:00.000Z',
      },
    },
  });
  check('percent=0 时丢弃占位重置时间', zero.single.resetsAt == null);

  final drifted = parseOpenCodeUsage(<String, Object?>{
    'usage': <String, Object?>{'rolling': 'unexpected'},
  });
  check('响应形状漂移时返回空而非崩溃', drifted.isEmpty);

  final tightest = go.reduce(
    (a, b) => a.usedPercent >= b.usedPercent ? a : b,
  );
  check('主标题取已用最多（剩余最少）窗口', tightest.isLimited);
}

void main() {
  print('Dart ${Platform.version}');
  probeA();
  probeB();
  probeC();
  print('\nchecks=$checks failures=$failures');
  if (failures > 0) {
    throw StateError('$failures check(s) failed');
  }
}
```

实测输出（最终一次）：

```text
Dart 3.10.7 (stable) (Tue Dec 23 00:01:57 2025 -0800) on "windows_x64"
checks=41 failures=0
```
