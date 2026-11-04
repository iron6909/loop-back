# 原 App 公开合集（临时本地归档）

2026-11-04 已完成：20 个合集、1,023 个媒体文件和 1,023 份 SRT；媒体合计 2,250,430,978 字节（约 2.25 GB），含元数据总计约 2.31 GB。全量 `--verify` 已通过 SHA-256、大小、字幕和目录完整性校验。

资源目录：`public_collections/`。来源是原 App 的匿名只读接口 `https://www.echo-loop.top/api/v2/collections`，遍历目录及每个合集的所有 `nextCursor`；不使用登录、Cookie 或 API Key。

运行与自检：

```powershell
python scripts/download_public_collections.py --check
python -u scripts/download_public_collections.py
python scripts/download_public_collections.py --verify
```

每个合集单独一目录；音频/视频保留接口给出的原文件格式，与同名 `.srt` 放在目录第一层。`collection.json` 保留排序和来源，`metadata/*.json` 保留原字幕（含逐词时间戳），`manifest.json` 记录实际下载结果、字节数和 SHA-256。根目录的 `manifest.json` 汇总各合集数量与容量。

重跑会校验并复用已完成文件；失败文件保留 `.part`，不会冒充完整文件。401/403 明确记为受限；404、传输或字幕错误记为失败，不尝试登录或绕过限制。脚本非零退出时检查清单，再重跑。

这些文件按用户要求仅暂存在项目中，不加入 Flutter assets 或 Git 提交。下载完成后可把某个音频合集目录复制到 Android，再用 Library「+ → 从文件夹导入」添加；视频原文件保留归档，目录导入按 App 当前支持范围处理。资源的版权和分发条件仍以原发布者为准。
