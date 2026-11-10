# 词典与发音库去 EchoLoop 化：实施任务与验收

> 2026-11-10。按 to-tickets 拆分，5 张纵向切片工单全部发布为 [spec #26](https://github.com/iron6909/loop-back/issues/26) 的子 issue 并应用 `ready-for-agent`。

## 工单与阻断边

| 编号 | 工单 | 阻断边 |
| --- | --- | --- |
| I1 | [#27 词典公开源与旧安装兼容](https://github.com/iron6909/loop-back/issues/27) | 无，可立即开始 |
| I2 | [#28 发音库公开源与安装兼容](https://github.com/iron6909/loop-back/issues/28) | 无，可立即开始 |
| I3 | [#29 词典设置页离线资源区](https://github.com/iron6909/loop-back/issues/29) | #27 + #28 |
| I4 | [#30 域名隔离收口：删除共享 CDN 配置与路由](https://github.com/iron6909/loop-back/issues/30) | #27 + #28 |
| I5 | [#31 迁移/备份回归与 Android 真机验收](https://github.com/iron6909/loop-back/issues/31) | #29 + #30 |

阻断边以子 issue 正文 `Blocked by` 与父 issue 子关系双重记录；无前置的 I1、I2 处于就绪前沿，可并行实施。

## 每张工单的验收入口

- **I1 / I2**：词典与发音库管理器的公开下载安装入口（注入 Dio/URL 的既有测试缝）+ 目录字段；独立下载核对（上游与镜像双源整包 SHA、解包逐文件与现有 CDN 归档比对）是实施第一步，核对通过前不把仓库名/revision 写成代码常量。
- **I3**：词典设置页 widget 测试 + 下载来源偏好与语音识别设置同源互见。
- **I4**：路由与配置测试更新 + 全仓库域名隔离回归（grep 无 `cdn.echo-loop`，历史归档文档除外）。
- **I5**：备份恢复真实往返、全量测试与分析、`scripts/check.sh`、Android 真机验收；Apple 编译待 macOS 宿主。

## 操作者前置行动（已完成，2026-11-10）

操作者已新建 HF 数据集仓库 `banko3/loop-back` 并上传三个归档与来源说明；固定 revision `3b3a5bef53a1c2c86f72117a8ce149554122baac`。双源独立下载核对已通过（huggingface.co 与 hf-mirror.com 整包 SHA/字节数与 CDN 原件逐字节一致），I1/I2 可直接引用该仓库与 revision。

## 范围外

数据重建/升级（ECDICT 重编译、zh-TW 繁体化、发音换源）、在线 TTS、词典引擎更换、按地区自动选择下载源、无关小清理（死 ARB 文案等单独立项）。
