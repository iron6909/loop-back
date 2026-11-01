# Design System

本文件记录 Echo Loop 已经交付的视觉系统，供后续界面保持一致。所有取值均来自现有实现（`lib/theme/app_theme.dart`、`lib/theme/tag_colors.dart`、`lib/widgets/`），不是新设计的规范；改动既有取值需要单独评审。

## Applicable surfaces

适用于全部 Flutter 界面（Android / iOS / macOS）。移动端优先，桌面端复用同一套 token。

三条跨界面硬约束：

1. **不依赖 tooltip 传达必要信息**。全局 `tooltipTheme` 已把尺寸压到 0、等待期设为 1 天，tooltip 实际不可见。必要说明必须用可见文本、行内辅助文字或对话框表达；`Tooltip` 只能作为无副作用的装饰。
2. **状态必须「图标 + 文字」双通道**。颜色不得单独承担含义（成功/跳过/失败、已限额、只读）。
3. **正文字号可缩放**。正文类文本经 `readingTextPrefs` 倍率缩放（85%–175%）；标签、chip、输入框等 UI 文字不缩放。

## Colors

品牌与结构：

| Token | Light | Dark (AMOLED) | 用途 |
| --- | --- | --- | --- |
| `seed` | `#1976D2` | `#1976D2` | `ColorScheme.fromSeed` 种子 |
| `scaffoldBackground` | `#F5F6FA` | `#000000` | 页面底色 |
| `surface` | `#FFFFFF` | `#0B0B0B` | 卡片 / AppBar / 底栏 |
| `surfaceBorder` | 无（靠阴影） | `#1F1F1F` | 深色卡片 1px 描边 |
| `sheet` | 默认 | `#1E1E20` | BottomSheet / 弹出菜单 |
| `surfaceContainer` 阶梯 | 默认 | `#101010` / `#161616` / `#1C1C1C` | 分层浮起 |
| `navActive` | `#3AA0FF` | `#3AA0FF` | 导航选中图标与标签 |

语义色：

| Token | 取值 | 用途 |
| --- | --- | --- |
| `success` | `#2E9E5B` | 完成、社区合集角标 |
| `successContainer` | `#E3F4E9` | 完成态浅底 |
| `warning` | `Colors.orange.shade700` | 跳过、部分成功 |
| `error` | `ColorScheme.error` | 失败、无效输入 |
| `bookmark` | `Colors.amber` | 收藏 |
| `pin` | `#E53935` | 置顶 |
| `localCollectionBadge` | `#1565C0` | 本地合集角标 |
| `communityBadge` | `#2E9E5B` | 社区合集角标 |
| `podcastCollectionBadge` | `#6A1B9A` | 播客合集角标 |
| `videoMediaType` | `#7655A6` / dark `#B39DDB` | 视频类型图标 |

中性色不额外染色：浅色沿用白/`#F5F6FA`，深色沿用分级近黑，均由 `ColorScheme.fromSeed` 派生后局部覆盖。

## Typography

单一字体族，沿用平台默认（`Roboto` / SF / 系统栈），不引入自定义字体。

| 角色 | 字号 / 行高 | 字重 | 来源 |
| --- | --- | --- | --- |
| AppBar 标题 | 17 / 默认 | 700 | `appBarTheme.titleTextStyle` |
| 分组标题 | `titleSmall` / 默认 | 600 | `AppTextStyles.sectionHeader` |
| 按钮文字 | 16 / 默认 | 600 | 各按钮主题 |
| 正文 | `bodyMedium` / 默认 | 400 | 主题默认 |
| 辅助说明 | 12 / 默认 | 400 | `AppTextStyles.label` |
| 极小说明 | 11 / 默认 | 400 | `AppTextStyles.caption` |
| 导航标签 | 12 / 默认 | 600（选中）/ 400 | `navigationBarTheme` |

数字列使用 `FontFeature.tabularFigures()`（导入进度、文件大小）。

## Spacing

基础单位 4，关闭集合（`AppSpacing`）：

| Token | 值 |
| --- | --- |
| `xs` | 4 |
| `s` | 8 |
| `m` | 16 |
| `l` | 24 |
| `xl` | 32 |

列表项内容内边距 12；导入列表行内边距 `horizontal 12 / vertical 7`。

## Radius / Elevation

| Token | 值 | 用途 |
| --- | --- | --- |
| `radiusInput` | 12 | 输入框、列表项、SnackBar、内嵌列表容器 |
| `radiusCard` | 16 | `Card`、各类按钮 |
| `radiusMenu` | 18 | `PopupMenuButton` |
| `radiusDialog` | 20 | `AlertDialog` |

高度：浅色卡片 `elevation 1` + 阴影 `black@8%`；深色卡片 `elevation 0` + 1px 描边（纯黑上阴影不可见）。AppBar `elevation 0`、`scrolledUnderElevation 0.5`。

## Component conventions

- **页面结构**：`AppBar` 左对齐标题 + 可滚动 `ListView`/`Column`；分组用「主色加粗分组标题 + `Card` 包 `ListTile` 列表 + `Divider` 分隔」。
- **行项目**：`ListTile`（leading 图标 / title / trailing 值 + `Icons.chevron_right`），点击进入子页或弹出选择。
- **反馈**：短反馈用 `SnackBar`（floating、圆角 12）；破坏性操作先用确认对话框。
- **空状态**：64px `outline` 色图标 + `titleLarge` 标题 + `bodyMedium` 说明 + 主操作按钮，垂直居中。
- **导入流程**：模态 BottomSheet（`isScrollControlled` + `showDragHandle`），逐项状态用图标表达，底部 `LinearProgressIndicator` + 文本标签，完成后显示汇总行（成功 / 跳过 / 失败各一行带图标）。
- **减少动效**：遵循系统设置；进度与状态不依赖动画表达。
