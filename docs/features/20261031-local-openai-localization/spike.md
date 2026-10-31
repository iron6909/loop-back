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

## Run: 2026-10-31 真实供应商 Key 与 Android 9 设备补证

### 问题与判定标准

沿用候选 A 的前提，本次用户补充了三家供应商凭据和一台 Android 真机，授权继续原有有界验证。此前“无凭据 / 无连接设备”的环境条件不再成立；前次实验方法和结果保留。

1. **真实结构化结果**：每家固定一个模型，对翻译、句子解析、单词、短语、意群、复述各发一次请求。必须得到正常完成的 JSON 对象，并通过代码中明确的字段 / 枚举 / 内容守恒检查；任一必要任务失败，该配置的六任务整体前提即不受支持，不能用重跑或换模型覆盖失败记录。
2. **聊天 SSE**：至少收到一段正文、正常 `finish_reason=stop` 和 `[DONE]`；记录首段正文与总耗时、usage 帧与空 delta 尾帧。
3. **真实账户查询**：使用当前推理配置的同一把 Key 查询，只记录 HTTP 状态与有限字段是否符合形状，不保存金额或账户身份。成功仅支持该 Key 在当时的权限，不能推及所有 Key。
4. **Android SAF 原生能力**：在隔离应用中，用户选择本次创建的合成目录；遍历直接子项、复制并比较字节数 / SHA-256，进程重启后仍能读取。未成功启动不算验证通过；与“仓库已有目录导入实现”是不同问题。

### 方法与条件

- 仓库：当前工作空间 `D:/Workspace/PersonalStudio/loop-back`，起点 `92a6a822b5a3569c4587c4da9b26c7a834c812c6`。初始没有已暂存或已跟踪文件差异；未跟踪的 `.env`、`.pi/` 属用户 / 工具状态，不提交、不修改其跟踪规则。
- 主机：Windows 10.0.26200；Dart 3.10.7 stable；adb 1.0.41（35.0.2-12147458）。供应商调用在主机的 `dart:io HttpClient` 上执行，**不等于 Android Flutter 网络路径已经验证**。
- 凭据：仅在进程内读取用户的 `.env`，变量名为 `DeepSeek_APIKEY` / `OpenRouter_APIKEY` / `OpenCode_APIKEY`。未把值写入源码、日志或报告；本轮只用公开造例，未发送设备文件或用户学习材料。早期错误输出包含账户标识，报告仅保留脱敏摘要，附件里的早期探针不适合作为产品日志实现。
- 样例：原句 `I have been looking forward to this trip for months.`；单词 `trip`；短语 `look forward to`；复述文本 `I look forward to this trip many months ago.`；SSE 问候 `Say hi in one short English sentence.`。完整提示词、请求参数、检查与 Android 构建命令见必需附件 [spike-live-probes.md](./spike-live-probes.md)。
- 主要矩阵为附件的 `business2.dart`：`temperature=0`、`response_format=json_object`；翻译 / SSE 上限 1200 tokens，意群 1500，其余任务 3000。DeepSeek 显式发送 `thinking:{type:'disabled'}`；Go 使用真实客户端名 `EchoLoop-feasibility-spike/0.1` 与同一组会话内稳定的随机 `x-opencode-session`。不伪装其他客户端。每项一次，失败返回非零，不自动重试。
- OpenRouter 模型由目录中正价格、单项价格不高于 0.000001/token 且宣称支持 `structured_outputs` 的候选按输入价与输出价之和选出。本次为 `mistralai/mistral-nemo`（合计价 5.9e-8/token）；这是单样例探针选取，不是产品默认模型选择。目录声明不保证实际路由按所有模式工作。
- 时延是单次串行请求的主机墙钟观测，含联网与供应商路由波动，不能当成统计性能基准。结构化请求没有测正文首字；只对 SSE 测首段正文。
- Android：Redmi Note 7 Pro，Android 9 / API 28；SDK platform android-35、build-tools 35.0.0、JDK 17 已安装。独立原生 APK 使用平台 `DocumentsContract`，无 AndroidX / Flutter / Gradle 新依赖，不申请网络或存储权限；包名 `dev.echoloop.spike.a3f1`，只接受合成目录 `Download/EchoLoopSpike_a3f1`。目标 SDK 为 28，本次不能代表现代 targetSdk 的存储限制。
- 本轮没有运行 Flutter 构建、应用测试或 `scripts/check.sh`，因为只增加证据文档、没有修改产品代码，且未建立 Flutter package_config。首次从项目根目录执行主机探针时出现 Flutter 依赖求解告警，但随后真实 HTTP 请求确实执行；复现应先切换到临时目录，避免该无关步骤。主要三份 Dart 探针的定向 analyze 为 `No issues found`。

### 观察结果

#### 1. 初版失败与协议差异

先做模型目录与只读接口探测，再跑初版 `business.dart`。保留失败，不把下列更正合并成“首次全部成功”：

- DeepSeek 模型目录 `GET https://api.deepseek.com/models` 返回 200，含 `deepseek-flash` 与 `deepseek-v4-pro`。初版只通过翻译（1/6），另外五项正文为空、响应含推理字段；当时上限分别为 600 / 600 / 700 / 400 / 700 tokens。该初版没有记录 `finish_reason`，所以“推理吃满预算”是文档与现象支持的解释，**不能声称当时已实测 finish=length**。
- DeepSeek 当前 [Thinking Mode 官方文档](https://api-docs.deepseek.com/guides/thinking_mode/) 写明默认开启 thinking、默认 effort high，OpenAI 格式通过 `thinking.type=disabled` 关闭。第二版同时关闭 thinking 并提高上限，因此它不是仅改一个变量的因果实验。
- Go 的 `.../inference/go/openai/v1/models` 与再追加 `/v1/models` 返回 404；`/zen/go/v1/models`、`/inference/go/v1/models` 均返回 200。Chat Completions 根路径仍是 `https://opencode.ai/inference/go/openai/v1`，模型目录不能机械地从该路径推导。
- 初版 Go 六项均返回 HTTP 400 `MissingSessionID`，没有业务结果；补稳定会话头和真实客户端名后才获得下一节结果。
- Go [官方文档“Where can I use it?”](https://opencode.ai/v2/docs/console/go/#where-can-i-use-it) 明确写面向 OpenCode / 其他编码代理，要求 typical coding agent traffic、自有 User-Agent、每段会话稳定的 `x-opencode-session`。**本英语学习场景是否得到服务支持未被证实**；不能通过伪装编码请求 / 客户端来推导适用性。两份官方页面均在本轮经 agent-reach 的 Jina Reader 路由读取。
- 初版 OpenRouter 模型 ID 被探针误抄成 `xingchen-agi/xing4.0-29b-a4f:free`，而目录为 `...-a4b:free`；返回 400 invalid model ID。这是探针输入错误，不能归咎为免费模型不可用。第二版改为从目录动态取低价付费模型。

#### 2. 六任务结构化矩阵（json_object）

表中为主矩阵单次总耗时，单位秒；失败时间同样保留。

| 任务 | DeepSeek / deepseek-flash | Go / deepseek-v4.1-flash | OpenRouter / mistral-nemo |
| --- | --- | --- | --- |
| 翻译 | 通过，1.655 | 通过，2.042 | 通过，3.515 |
| 句子解析 | 通过，3.361 | 通过，7.839 | 通过，3.356 |
| 单词 | 通过，4.079 | **失败，23.887：finish=length** | 通过，32.678 |
| 短语 | 通过，3.943 | 通过，10.154 | 通过，36.923 |
| 意群 | 通过，1.049 | 通过，9.353 | **失败，4.741：字段类型导致 TypeError** |
| 复述 | 通过，2.866 | 通过，10.710 | 通过，21.932 |
| 结构化检查合计 | **6/6** | **5/6** | **5/6** |

- Go 单词请求的 `finish_reason=length`、`completion_tokens=3000`，所以明确拒绝；没有因其返回 HTTP 200 就算成功。未继续增加 token 重跑，不推断增加预算就必能成功。
- OpenRouter 意群的外层完成原因为 `stop`，但模型结果的 medium 或 fine 是字符串而非数组，现有 `SenseGroupResult.fromJson` 触发 `type 'String' is not a subtype of type 'List<dynamic>?'`。原始 JSON 未保存，不能回溯断言究竟是哪一个字段。
- DeepSeek 的意群 medium 长度为 **1**、fine 为 3；通过现有内容守恒不代表节奏拆分质量合格。Go 为 2 / 3。复述评级 DeepSeek 为 poor，Go 与 OpenRouter 为 fair；没有人工评分基准，不能用有效枚举认定评分准确。
- 所有“通过”指本附件内明确执行的检查。尚未覆盖全部嵌套字段上限、目标语言一致性、恶意提示词、复杂句、多个样例或重复运行稳定性；不称为完整产品 schema 或模型质量验收。
- 主矩阵 21 项（18 结构化 + 3 SSE）中失败 2 项，`failures=2`，退出码 1。这是两个不支持结果的证据，不是成功测试套件。

#### 3. SSE 尾帧与首段正文

| 供应商 | 首段正文 ms | 总耗时 ms | 正文分片 | usage 帧 | 空 choices 帧 | 空正文 finish 帧 | stop / DONE |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DeepSeek | 1174 | 1266 | 3 | 1 | 0 | 1 | 均收到 |
| Go | 1182 | 1332 | 4 | 1 | 0 | 0 | 均收到 |
| OpenRouter | 3036 | 3102 | 2 | 1 | 0 | 2 | 均收到 |

OpenRouter 本次出现两个不带正文的 finish 帧，支持“尾部重复完成信息不可当作新增正文”的处理。未人为断网、取消或切换配置，没有证明异常 EOF、跨所有网络边界和取消逻辑正确。

#### 4. 真实账户接口

| 请求 | HTTP | 只记录的结果 |
| --- | --- | --- |
| DeepSeek `/user/balance` | 200 | 1 个币种；三种金额均可解析；is_available 是 bool |
| OpenRouter `/api/v1/credits` | 200 | total_credits 与 total_usage 均为数值 |
| OpenRouter `/api/v1/key` | 200 | limit_remaining、limit、limit_reset 均为 null；无 effective_budget 对象 |
| Go `/zen/go/v1/usage` | 200 | rolling / weekly / monthly 三窗口的 status、percent、resetsAt 均符合读取形状 |

- OpenRouter **本次同一把能推理的 Key 也能查询 /credits**。没有枚举该 Key 的管理角色，不能证明所有“普通推理 Key”都可读取，更不能断言权限文档错误。此前对“普通 Key 已获余额”的口头描述过强，以本条界定为准；仍应保留 401 / 403 权限处理与 Key 预算为空分支。
- Go 初次观测 rolling.percent=0 且带 resetsAt。该现象只证明“0 值仍有时间字段”存在，不能单靠该响应证明时间一定是占位值；丢弃零值时间是提案既有保守展示策略。
- 本次未测无 Go 套餐的 403、失效 Key、余额为零、真实 rate-limited、多币种余额与额度恢复；前次合成边界仍只是合成边界。
- 前次把三家样例统称“官方示例”不精确：Go 用量形状来自提案已列的 Magpie / 社区来源；本次真实 200 补充了运行证据，并不倒推其最初来源是官方。

#### 5. 意群类型边界更正与严格 Schema 对照

前次五模型均可解析空对象、SentenceAnalysis 可容忍所测错误类型，这些观察保留；**“五种模型在类型错误下一律静默成功”不成立**。源码明确将 medium / fine 强转为 List，独立对照探针分别传入字符串验证该边界。产品端需在模型构造之前做严格结构校验，并映射异常，不能把展示半成品的容错约定当作信任边界校验。

严格 Schema 对照：固定同一 OpenRouter 模型、原句、提示词、1500 token 上限，仅改为 `json_schema`（strict、required、additionalProperties=false）并加 `provider.require_parameters=true`。只执行一次，返回 HTTP 200、`finish_reason=stop`；两组均为非空字符串数组，均通过现有内容守恒，总耗时 **6437 ms**。中粒度 1 段、细粒度 11 段；没有人工节奏质量评判，不能把形状正确当作有教学价值的切分。

独立探针实际输出如下；前两项是本地类型边界断言，后两项才是真实网络对照：

```text
LOCAL medium=String throws TypeError=true
LOCAL fine=String throws TypeError=true
SCHEMA http=200 ms=6430
SCHEMA PASS finish=stop medium=1 fine=11 conserved=true totalMs=6437
```

探针退出码 0，支持“该模式在本模型、本样例上能返回通过检查的数组”。这次同时改变了输出模式与路由约束，且供应商内部路由可能变化，因此不证明单一参数的因果效果、所有模型均支持严格 Schema，或重复运行稳定。上一矩阵的 `json_object` 失败不被覆盖。

#### 6. Android 安装阻塞

独立 APK 在已装 SDK / JDK 下编译、DEX、签名及签名验证成功（`BUILD PASS probe.apk`）；创建了合成目录的 5 个顶层文件和 1 个子目录，子目录含 1 个文件。媒体扩展名文件的内容是短文本标记，**只用于 URI 字节读取，不可当音频解码样本**。

两次 `adb install -r probe.apk` 均被 MIUI 拒绝，错误为 `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`；屏幕通知显示手机管家已拦截 USB 安装。已唤醒设备并确认可进入主屏幕，第二次仍被拦截。没有关闭安全开关、绕过限制或尝试访问其他目录；已向用户说明需在设备侧放行。当前没有成功启动 APK，没有得到 tree URI 或读取结果，因此不能记为 Android SAF 验证成功。

### 结论与限制

| 问题 | 结论 | 精确范围 |
| --- | --- | --- |
| DeepSeek 六任务的初步结构化可用性 | **Supported（本样例）** | 关闭 thinking，使用本次 token 上限，6/6 通过所列检查；意群质量与评分准确性仍未证明 |
| Go 六任务在本配置下全部可用 | **Not supported** | 5/6；单词触发 length；另有编码代理用途适配未证实 |
| OpenRouter json_object 六任务全部可用 | **Not supported** | 5/6；意群字段类型不符；严格 Schema 是单独对照，不覆盖此失败 |
| OpenRouter 严格 Schema 意群对照 | **Supported（本样例）** | 同模型一次返回合规数组且守恒，6437 ms；中粒度仍为整句，未证明拆分质量或稳定性 |
| SSE 正常完成 | **Supported（本次正常连接）** | 三家都有正文、stop、DONE 与 usage；取消 / 断流未验证 |
| 用同一 Key 读取真实用量 | **Supported（这三把 Key）** | 四请求 200，字段可读；不推及其他账号、Key 角色或错误分支 |
| 意群类型错误不抛异常 | **Not supported** | medium / fine 分别传入字符串均实测抛 TypeError；更正前次过宽概括 |
| Android 目录选择、复制与重启授权 | **Inconclusive** | 设备已连接，安装被设备安全策略拦截；从“缺设备”更新为“需设备放行” |

### 对设计的影响与停止条件

1. 标准 Chat Completions 可承载本例学习任务，但兼容供应商仍需明确的端点、thinking / token、session 和输出模式适配；不等于三家所有必要功能都已可用。
2. 最终结果必须同时检查正常完成、JSON 类型、必填字段与业务守恒；语法正确 / HTTP 200 / fromJson 不抛均不够。Go 的截断与 OpenRouter 的类型错误提供了真实拒绝样本。
3. OpenRouter 余额查询宜按实际权限降级，不能强制将所有同类 Key 视为“可查”或“不可查”；无预算为 null，不能替代账户余额。
4. Go 用于英语学习的服务适用性需交回 ideate 处理，不能通过请求伪装解决。
5. 本次严格 Schema 对照已给出“本例结构可修正”的有限证据；不再扩充模型、样例或反复试到全绿。Android 等待用户放行，原生可行性与应用端到端结果仍是证据缺口。仅为继续该设备探针保留本轮临时 APK 与原生源码；供应商探针源码已完整入附件，未加入产品。
6. 文档检查已确认前次报告原文完整保留、附件 10 份源码可逐字重建、代码围栏成对，且两份文档均不含 `.env` 中的 Key 值；从附件提取的三份主要 Dart 探针定向 analyze 无问题。探针主矩阵的两个负面结果不改写为测试成功；未执行 `scripts/check.sh`，原因是本次交付仅为证据文档，没有产品代码变更。

本轮不修改 proposal.md、产品代码或下游合同，不选型、不进入实现；证据交回 **ideate** 比较候选与必要的约束。

## Run: 2026-10-31 Android SAF 目录读取补证

### 问题与判定标准

**候选**：`ideate` 修订后的 S3a——新增原生 SAF tree picker（`ACTION_OPEN_DOCUMENT_TREE` + `DocumentsContract` 子项遍历 + `openInputStream` 读取 + 持久化读权限），目录内文件交给现有 `classifyImportFiles` / `matchSubtitlesForAudios`。

**依赖的设计选择**：S3a 是否可替代 `file_picker` 的目录接口（S3b）；若 S3a 在真机不可行，S3 需重新比较。

**判定标准**（全部满足才算 Supported）：

1. 用户选择本次创建的合成目录后，探针能遍历出 5 个直接子项与 1 个子目录，且不递归进入子目录。
2. 每个文件经 `ContentResolver.openInputStream` 读出后，字节数与 SHA-256 与主机按同一输入算出的期望值逐一相等。
3. `takePersistableUriPermission` 生效：进程被 `am force-stop` 杀死后重新启动，仍能在无新授权的情况下读到同一批字节。
4. 只接受该合成目录；误选或越界应被拒绝而不是继续读取。

前次运行此项为 **Inconclusive**，原因是 MIUI 拒绝安装探针（`INSTALL_FAILED_USER_RESTRICTED`），未产生任何 SAF 结果。本次目标是补上该缺口。

### 方法与条件

- 设备：Redmi Note 7 Pro，Android 9 / API 28，USB 调试已授权。产品 `android/app/build.gradle.kts` 使用 `minSdk 24` 与 `flutter.targetSdkVersion`；本机 Flutter 3.10.7 的 `FlutterExtension.targetSdkVersion = 36`，故产品实际为 **targetSdk 36**。
- 探针：独立原生 APK，包名 `dev.echoloop.spike.a3f1`，无 AndroidX / Flutter / Gradle 依赖，不申请网络与存储权限，只接受 `Download/EchoLoopSpike_a3f1`。源码与构建脚本见必需附件 [spike-live-probes.md](./spike-live-probes.md)。
- 两种构建：**A 版** `minSdk 26 / targetSdk 28`（沿用前次产物）；**B 版** `minSdk 24 / targetSdk 36`（与产品一致）。B 版经 `aapt2 dump badging` 确认 `minSdkVersion:'24'`、`targetSdkVersion:'36'`。
- 合成输入：`01.mp3`(30 B)、`01.srt`(45 B)、`02.MP3`(26 B)、`02.vtt`(32 B)、`notes.txt`(7 B)，加子目录 `sub/inner.mp3`(6 B)。媒体扩展名文件内容是短文本标记，**只用于 URI 字节读取，不是可解码音频样本**。期望 SHA-256 由主机按同一 UTF-8 输入预先算出。
- 驱动方式：`am start` 启动探针 → `input tap` 点击选择按钮 → 在系统 DocumentsUI 中确认目录 → 读 `logcat -s EchoLoopSpike_a3f1:I`；随后 `am force-stop` 并以 `--ez check true` 重启复验持久化。选择动作由真实 DocumentsUI 完成，未绕过系统授权界面。

### 观察结果

#### 1. A 版（targetSdk 28）通过全部四项

安装首次成功（此前同一命令连续失败两次，`INSTALL_FAILED_USER_RESTRICTED`）。启动后 `DocumentsUI` 直接定位到目标目录，界面显示 `sub/` 与 5 个文件，名称与大小与 fixture 一致。

选择后日志：

```text
PHASE picked persisted=true files=5 directories=1
FILE 01.mp3 bytes=30 sha256=c19e23aa122e2a69acaf31fb882a16939b74c7c1a851e49b0d5c2b71ed7eb524
FILE 01.srt bytes=45 sha256=490f2542b4fe9b875f80fa1c0a8dec5161da8f214f497b07f5a3ffa3fb01dfc7
FILE 02.MP3 bytes=26 sha256=3845f85a816777e82d97a17c6f55fd98ffd4ff70d40a8f88e7727ce13dce1537
FILE 02.vtt bytes=32 sha256=e1dcfceb7592f776940af39adf26183f3377f2e53651d9c14b31c07aeadc7031
FILE notes.txt bytes=7 sha256=3514cf816e5407a39cb7a1c1e1243f176dda121e06398a8934edb1dc426b0b34
END picked
```

`force-stop` 后以 `--ez check true` 重启（进程 PID 由 9866 变为 10287），持久化授权仍可用：

```text
PHASE persisted persisted=true files=5 directories=1
FILE 01.mp3 bytes=30 sha256=c19e23aa122e2a69acaf31fb882a16939b74c7c1a851e49b0d5c2b71ed7eb524
... （其余 4 项与上一段逐一相同）
END persisted
```

五个文件的字节数与 SHA-256 与主机期望值**全部相等**；`directories=1` 且 `sub/inner.mp3` 未被列出，说明遍历只取直接子项、未递归。`02.MP3` 的大写扩展名被原样保留为显示名，符合现有 `_extensionOf` 的小写归一化前提。

一次未解释的异常：首次启动瞬间（19:08:09）记录到一条 `CANCELLED no read attempted`，当时未弹出选择器，随后点击按钮正常进入。该条日志的触发来源未能确定，未影响后续结果；不将其解释为通过或失败。

#### 2. B 版（targetSdk 36）未能执行

为消除「测的是另一种存储制度」的代表性缺口，我卸载 A 版以撤销旧授权（保证 B 版是干净的一次授权），重装 B 版。此后 MIUI 再次拦截，且这次没有任何可见确认界面：

- `adb install -r` 连续失败：`INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`。
- 唤醒并解锁设备后重试仍失败；`dumpsys window` 焦点始终是 `StatusBar` 或桌面，未出现安装确认弹窗；手机管家通知区有拦截角标。
- 改用设备端安装器路径（`adb push` 到 `Download/` 后 `am start -a android.intent.action.VIEW -t application/vnd.android.package-archive -d file:///...`）也未弹出界面，`pm list packages dev.echoloop.spike.a3f1` 仍为空。
- 未修改任何设备安全设置、未关闭手机管家、未尝试其他绕过手段。

因此 **B 版（产品 targetSdk 36）的 SAF 行为没有任何实测数据**；A 版证据保留，当前设备上探针已不在安装状态。

#### 3. 未执行的部分

- 误选非目标目录时的拒绝分支：未在设备上实测（探针有该检查，但未触发）。
- 取消选择、空目录、现代 Android（API 29+）分区存储、非 `externalstorage` 的 document provider：均未测。
- `classifyImportFiles` / `matchSubtitlesForAudios` 用真机返回的文件名跑一遍：未执行。二者位于 `lib/features/audio_import/subtitle_pairing.dart`，其依赖链 `audio_item.dart → app_data_dir.dart` 引入 `package:flutter/foundation.dart` 与 `path_provider`，纯 Dart 探针无法导入；改用 Flutter 测试需要 `flutter pub get` 生成 `package_config.json`，会改动仓库状态，超出本次范围。
- 应用端到端（真实 Echo Loop 里选目录导入并入库）：未执行，本轮只验证原生能力。

### 结论与限制

| 问题 | 结论 | 精确范围 |
| --- | --- | --- |
| SAF 目录选择 + 子项遍历 + 字节读取 | **Supported** | Android 9 / API 28，targetSdk 28，探针 APK；5 文件哈希逐一相等，子目录未递归 |
| 持久化授权跨进程重启 | **Supported** | 同一设备，`force-stop` 后新 PID 仍可读；未测跨应用升级、跨重启或长期有效 |
| 同一行为在产品 targetSdk 36 下成立 | **Inconclusive** | B 版安装被 MIUI 拦截，零实测数据 |
| 误选拒绝分支 | **Inconclusive** | 代码存在但未在设备上触发 |
| 目录内文件可交给现有配对逻辑 | **Inconclusive** | 仅确认显示名为干净文件名；配对函数未在真机数据上运行 |

本轮确立：SAF 机制在这台 Android 9 设备上确实能完成「选目录 → 列子项 → 读字节 → 重启后仍可读」，且字节级正确。它**不**确立：产品 targetSdk 36 下同样成立、其他 Android 版本或厂商 ROM 行为一致、错误分支可靠、应用层集成可用。

### 对设计的影响与剩余缺口

1. S3a 的核心机制前提已得到真机支持，`file_picker`（S3b）不再是必需项；但该支持只在 targetSdk 28 下取得。
2. targetSdk 差异的残余风险需要说明：SAF 读取走 content URI 与 `ContentResolver`，不受分区存储对文件路径的限制，理论上与 targetSdk 无关；但这只是推理，本轮没有实测，不能当作已验证。
3. 未解释的首次启动 `CANCELLED` 与 MIUI 的安装拦截都属环境噪声，说明该机型上的系统 UI 行为不完全可预期；实施时不能假定选择器一定弹出、一定返回 OK。
4. 建议 `ideate` 据此更新 S3 的推荐：保留 S3a，并把「在 targetSdk 36 下重跑本探针」列为实施首步验收，而不是选型前置条件。
5. 未修改 `proposal.md`、产品代码或下游合同；本轮仅新增证据。设备上仍留有合成目录 `Download/EchoLoopSpike_a3f1` 与 `Download/EchoLoopSpike_a3f1_probe.apk`，用于后续重试，清理待本轮验证结束后进行。
