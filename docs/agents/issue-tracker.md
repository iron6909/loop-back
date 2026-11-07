# Issue tracker: GitHub

本仓库的规格和任务发布到 GitHub Issues：
https://github.com/iron6909/loop-back/issues

使用 gh CLI，所有操作显式指定仓库 iron6909/loop-back。
本地设计文档提供背景，GitHub issue 承载票据状态。

## 操作约定

- 发布前核对目标仓库：gh repo view iron6909/loop-back --json nameWithOwner,hasIssuesEnabled,viewerPermission
- 创建：gh issue create --repo iron6909/loop-back --title "<标题>" --body-file "<正文文件>"
- 读取：gh issue view <编号> --repo iron6909/loop-back --json number,title,body,labels,comments
- 列表：gh issue list --repo iron6909/loop-back --state open --json number,title,labels
- 更新正文：gh issue edit <编号> --repo iron6909/loop-back --body-file "<正文文件>"
- 评论：gh issue comment <编号> --repo iron6909/loop-back --body-file "<正文文件>"
- 标签：gh issue edit <编号> --repo iron6909/loop-back --add-label "<标签>"
- 关闭前先发布处理说明，再执行 gh issue close <编号> --repo iron6909/loop-back。

多行正文写入 UTF-8 文件，通过 --body-file 提交。
发布前检查重复票据；发布后回读正文与标签，记录 issue URL。
分流标签使用 triage-labels.md 中的映射。

## 子任务与依赖

优先使用 GitHub 原生子 issue 和阻塞关系。
不可用时，在正文记录 Part of #<父编号> 和 Blocked by: #<阻塞编号>。
全部阻塞票据关闭后，任务才可开始。

## PR triage

PRs as a request surface: no.

## 技能语义

“发布到 issue tracker”表示创建 GitHub issue。
“读取相关票据”表示读取对应 issue 的正文、标签和评论。

## Wayfinding

地图使用一个带 wayfinder:map 标签的 issue。
决策票据作为地图的子 issue，使用对应 wayfinder 类型标签。
待处理项为未关闭、未认领且没有未关闭阻塞项的子 issue。
认领时分配给执行者；解决后记录结论、关闭票据并更新地图引用。
Wayfinding 标签与普通 triage 状态分开使用。
