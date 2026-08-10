# 授权内容归档器改造方案

基线：`Notsfsssf/pixez-flutter` `master@d4893fbdc65f8c247e67a85e0610c0de430034df`（2026-08-05）。

## 1. 产品边界

目标应定义为“授权内容管理与离线缓存工具”，而不是站点爬虫。

- 不枚举作品 ID、用户或付费内容。
- 不导入浏览器 Cookie，不接收站点账号密码。
- 不绕过验证码、付费墙、防盗链、访问控制或速率限制。
- 不调用网页内部接口，也不伪装成官方 App。
- 只有同时具备 `platform_entitlement`、`intentional_download_channel`、
  `copyright_basis` 三项依据时才下载；否则仅保存链接和元数据。
- 缓存仅属于当前用户，不跨账号去重、不共享签名 URL 或私有 RSS。

## 2. 为什么不能直接扩写 PixEz 网络层

PixEz 是 GPL-3.0 第三方 Pixiv 客户端，不是通用爬虫框架。它的 UI、模型、
全局状态和 `ApiClient` 都直接依赖 Pixiv 移动 App 私有接口。当前实现还内置了
移动端 OAuth 客户端标识、签名盐和官方 App 风格请求头。

Pixiv 现行条款禁止使用 crawler 或其他程序聚合作品；目前也没有找到供普通
第三方注册、具有稳定文档的通用作品 API。因此不新增 Pixiv 自动连接器。
可保留的 Pixiv 方向只有：

1. 用户手动导入自己合法持有的文件；
2. 作者导入自己的原稿目录；
3. 保存作品 URL、作者、授权说明、哈希和导入时间；
4. 取得 Pixiv 书面许可或未来正式公开 API 后，再单独评审网络连接器。

如果分发基于本仓库修改的程序，必须继续遵守 GPL-3.0，提供对应源码并保留
许可证和修改声明。GPL 不授予 Pixiv 商标、站内作品或接口的使用许可。

## 3. Patreon 可实现范围

### `patreon_creator_archive`

由 campaign 创作者本人通过 Patreon API v2 OAuth 授权：

- 同步自己的 campaign、tiers、benefits、members 和 posts；
- 使用 cursor 分页与 webhook 做增量同步；
- 仅保存 API 正式返回的文本、元数据和可用图片字段；
- API 未提供的上传图片、featured image 或附件不通过网页抓取补齐。

移动/桌面程序不得内嵌 OAuth client secret。应使用 HTTPS 后端完成授权码交换，
应用只接收短期 access token/轮换后的 refresh token；令牌进入系统凭据库。

### `patreon_private_rss`

由用户手动粘贴自己的 Patreon 私有音频 RSS：

- RSS URL 按密码处理，只保存在本机系统凭据库；
- 仅缓存 feed 明确提供的 enclosure 音频；
- 支持 ETag、Last-Modified、断点续传和指数退避；
- 不上传 RSS、不共享文件、不建立公共索引；
- 用户退出或失去 entitlement 后停止新增同步，保留策略由用户明确选择。

赞助者 OAuth 不能通用读取其所赞助的其他创作者的付费帖子。Patreon 页面、
Shop、任意附件也不做 Cookie/网页接口抓取。

## 4. 建议的新架构

```text
UI
 └─ Archive use cases
     ├─ PolicyGate
     ├─ ImportCoordinator
     ├─ DownloadCoordinator
     └─ Search/Export
         ├─ LocalImportProvider
         ├─ PatreonCreatorProvider
         └─ PatreonPrivateRssProvider

Storage
 ├─ SQLite metadata and entitlement evidence
 ├─ OS credential vault for tokens/RSS URLs
 └─ Content-addressed local files scoped by account
```

网络 provider 只能返回统一领域模型，不允许 UI 直接依赖站点 JSON。每个 provider
有独立认证、限流、缓存命名空间和可撤销开关。

核心记录至少包含：

- `source`, `source_item_id`, `canonical_url`；
- `creator_id`, `creator_name`, `published_at`；
- `platform_entitlement`, `intentional_download_channel`, `copyright_basis`；
- `local_path`, `byte_length`, `sha256`, `downloaded_at`；
- `account_scope`, `access_expires_at`, `provenance_json`。

下载状态机使用：

`queued -> downloading -> verifying -> committing -> completed`

失败分支保留 `failed/cancelled`，下载先写 `.part`，校验长度/哈希后原子提交。

## 5. 本分支已经完成的第一批修复

- 文件名组件统一清洗，阻止路径分隔符、控制字符、Windows 设备名、尾随点/空格
  和超长名称进入落盘路径；图片扩展名从 URL path 判断而不是简单字符串包含。
- 下载任务表补写 `medium` 字段，数据库升级到 v3，清理旧重复 URL 并建立唯一索引。
- 等待平台保存结果后才把任务标记成功；失败任务进入 error 状态；成功后清理临时文件。
- Android 同名并发保存会明确返回冲突，不再让 MethodChannel Future 永久挂起；
  iOS/macOS 等到 Photos 最终回调后才报告成功。
- 下载队列的异步异常不再被空 `catch` 吞掉。
- OAuth/API 调试日志不再输出请求/响应正文或请求头，刷新日志不再打印 bearer token。
- token 刷新改为单次共享刷新，并按请求记录认证/网络重试次数。
- DNS 兼容模式重新启用证书校验、WebPKI 根证书和 SNI，不再为直连关闭 TLS 身份验证。
- 标签搜索结果可按当前已加载集合的收藏量或浏览量降序排列；分页追加后重新计算，
  同值作品保持服务端原顺序，不会为了生成“全站榜单”自动遍历所有分页。
- 搜索结果可按 Pixiv 结构化作品类型筛选为 `illust`（插画）或 `manga`（漫画/本子）；
  `fanart` 不是稳定的接口类型。筛选改为非破坏性派生列表，并保留显式继续加载入口。

## 6. 验证门禁

当前机器没有 Flutter/Dart SDK，也缺 Android 完整 SDK，因此本分支尚不能声称已
编译通过。安装与 `pubspec.yaml` 匹配的 Flutter stable 后，至少运行：

```powershell
$ErrorActionPreference = 'Stop'
flutter pub get
flutter test test/utils/file_name_sanitizer_test.dart test/utils/illust_result_options_test.dart test/models/task_persist_test.dart
flutter analyze
flutter build windows
```

后续必须增加：数据库 v1/v2 到 v3 迁移测试、并发 token 刷新测试、账号隔离缓存
测试、下载中断恢复测试、TLS 失败测试和 Windows 实际目录落盘测试。

## 7. 参考边界

- Pixiv Terms: https://policies.pixiv.net/en.html
- Pixiv anti-scraping engineering note: https://inside.pixiv.blog/2023/05/17/102629
- Patreon API v2/OAuth: https://docs.patreon.com/
- Patreon rate limits: https://docs.patreon.com/#rate-limiting
- Patreon private audio RSS: https://support.patreon.com/hc/en-us/articles/360041347732-How-to-use-your-audio-RSS
- Patreon Security Policy: https://www.patreon.com/policy/security
- Patreon Terms: https://www.patreon.com/policy/legal
