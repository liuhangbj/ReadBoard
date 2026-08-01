# ReadBoard 待办

## 新信源接入

> 可行性研究结论见 `docs/信源接入可行性研究.md`（2026-07-30 实测，2026-07-31 修订抖音结论）

- [ ] **per-source 认证基建**（B站 / 知识星球共同依赖，建议先做）
  - `content_source.config` 增加 `auth` 字段；`FeedFetcher` 支持注入认证头。
  - token 存 `SecretStore`（AES-GCM），UI 提供密码输入框。
  - 当前 `FeedFetcher` 不发任何 auth header，这是所有私有源接入的共性缺口。

- [ ] **哔哩哔哩信源**（可行性最高，建议排在知识星球之前）
  - Phase 1：收藏夹信源（`/x/v3/fav/resource/list`，**零签名零 Cookie**，实测直通）。
  - Phase 2：UP 主动态流（`/x/polymer/web-dynamic/v1/feed/space`，需 WBI 签名 + `buvid3` 指纹，实测 `code=0`）。
  - WBI 签名为纯 MD5 算法，Swift/CryptoKit 可直接实现，无 JS 依赖。
  - 视频走 `meta.audio_url` 复用现有 `TranscribePipeline`；需在 `SourceStore.swift:82` 的 `transcribable` 加入 `bilibili`。
  - 专栏/图文正文随接口直接返回，可置 `fetch_status=2` 跳过 `FullTextFetcher`。

- [ ] **知识星球信源**（方案已就绪，不着急实现）
  - 完整实施方案（函数级）：`~/.workbuddy/plans/radiant-forging-turing.md`。
  - 新增 stype `zsxq`；`ZsxqFetcher` 复用 `ParsedEntry` → `upsertContent`。
  - token 由用户手填（有效期 1–3 月），存 `SecretStore`。
  - 采集范围：主题帖 + 内嵌音频/图片；音频经 `meta.audio_url` 自动流入转写管线。
  - 仅限个人已订阅星球、非商用。

- [ ] **抖音信源**（2026-07-31 修订：由「不可行」改为「可行」）
  - **不逆向 a_bogus**，改用离屏 `WKWebView` 让抖音自己的 JS 生成签名。Readboard 已 `import WebKit`，无新依赖。
  - 实测（Chromium）：页面内 `fetch aweme/v1/web/aweme/post/` → `status_code=0`、16 条、`has_more=1`、
    带 `max_cursor` 游标，**零登录零 Cookie**。同一请求在浏览器外裸发 `size=0`。
  - 链路：短链 `v.douyin.com/xxx` 一次 302 → `sec_uid`（= 用户「分享名片」复制的链接）。
  - 字段齐全：`aweme_id / desc / create_time / play_addr(无水印直链) / cover / images[] / statistics`。
  - 落地：`guid=aweme_id`，`identifier=sec_uid`，`play_addr` → `meta.audio_url` 复用 `TranscribePipeline`；
    `SourceStore.swift:82` 的 `transcribable` 加入 `douyin`。
  - **前置必测**：WKWebView(WebKit) 与 Chromium 是否等价——抖音可能对 Safari 内核有不同指纹策略。
  - 限制：单次仅首页 ~16 条，翻页第 2 页返回 0。对"每日增量"无影响（对照：得到大脑也是每日 8 点只取前一天）。
  - 频率必须克制：每源每日 1 次、源间随机延迟。个人自用、非商用。
  - 排在哔哩哔哩之后——它引入「浏览器引擎参与后台同步」这一新架构模式，宜在信源管线稳定后再做。

- [ ] **离屏 WebView 采集器基建**（抖音方案的核心，长期价值高于单个信源）
  - 封装通用能力：无 UI 加载页面 → 等待 JS 初始化 → `evaluateJavaScript` 页面内取数 → 回传 JSON。
  - 任何"需浏览器环境才能取数"的平台都可复用。
  - 可选扩展（小红书依赖）：持久化 `WKWebsiteDataStore` + 内置扫码登录 + 登录态过期检测。

- [ ] **小红书信源**（2026-07-31 修订：由「不可行」改为「技术可行，风险自担」，**默认不排期**）
  - 原判「鉴权层硬拦截、无解」不准确。实测证明：**签名层已解决，登录态可在应用内正当取得**。
  - 签名：页面直接暴露 `window._webmsxyw(path, body)` → 返回 `{X-s, X-t}`，**无需逆向**。
  - 扫码登录（官方接口，未登录即可调用）：
    - `POST /api/sns/web/v1/login/qrcode/create` → `code=0`，返回 `qr_id / code / url`。
    - `GET  /api/sns/web/v1/login/qrcode/status?qr_id=&code=` → `code_status`：0 未扫 / 1 已扫待确认 / 2 已确认 / 3 失效。
    - 把 `data.url` 渲染成二维码供用户用小红书 App 扫描即可。
  - 登录态持久化：`web_session`（httpOnly，`.xiaohongshu.com`，**有效期约 1 年至 2027-07-31**），
    `WKWebsiteDataStore` 可直接持久化，无需手工搬运 Cookie。
  - 取数方式比抖音更简单：**不必手工拼签名头**（手拼缺 `x-s-common` 会得 461）。
    登录后直接导航博主主页，页面自身 JS 会发出带完整签名的 `user_posted`，Swift 侧只拦截响应。
    解析 `data.notes[]`（`note_id / display_title / type / interact_info`），`cursor` + `has_more` 做增量。
  - **未登录实测对照**：博主主页正文仅 133 字、强制弹扫码登录墙、`user_posted` 根本不发出；
    首页 `/explore` 虽能渲染 29 条，但那是算法推荐流，非订阅入口。
  - **唯一真正的卡点是账号风险，不是工程**：需用户真实主账号长期登录在 App 内，
    小红书对非官方客户端风控最激进，异常频率可能限流或封号，社交资产损失大于功能收益。
  - 若要做，三个前置条件：① 排在抖音之后（复用同一 WebView 基建，抖音无需登录态、是更安全的验证载体）；
    ② 添加信源时必须有明确的账号风险告知 UI；③ 保守同步：单博主每日 1 次 + 随机延迟 + 失败退避。

## 其他

- [ ] 全局“工作语言”设置
  - 当前阶段继续采用中文优先逻辑，不调整现有行为。
  - 后续在“AI 内容处理”中提供全局工作语言，并统一作为摘要、翻译和转录译文的目标语言。
  - 内容原语言仍由 Feed、正文或 Whisper 自动识别；工作语言不得传给 Whisper 代替原语言识别。
  - 当内容语言与工作语言一致时跳过翻译；不一致且翻译功能开启时才翻译。
  - 届时移除翻译模块内重复的“输出语言”设置，并清理代码中写死的中文判断。
