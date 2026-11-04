# 精选播客来源

`catalog.json` 是原 App 匿名接口 `https://www.echo-loop.top/api/v1/featured-podcasts` 在 2026-11-04 的完整快照：4 页、66 项；保留原顺序、ID、RSS、Apple Podcasts 地址、图片和说明。App 只读取随包文件，不请求该目录接口。

更新时沿 `nextCursor` 取到空值，检查 ID 唯一且每项都有可订阅地址后整体替换清单；运行 `flutter test test/features/podcast/featured_podcast_service_test.dart`。节目媒体仍由发布者提供，各域名的网络可达性独立于目录。
