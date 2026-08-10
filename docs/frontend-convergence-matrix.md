# ReadBoard Core / Go 前端收口验收矩阵

本文件是 Core、Pro 与 Go 前端共享化的唯一验收基线。迁移完成不以“页面存在”或“外观相似”为准，而以每个最小功能点在两端行为一致、权限明确、数据通路可验证为准。

## 状态定义

- `shared-live`：Core 与 Go 都直接使用同一份 `ReadBoardFeatures` / `ReadBoardUI` 实现。
- `shared-ready`：共享实现已存在，但至少一端仍运行兼容实现。
- `duplicated`：Core 与 Go 仍有两份页面或状态逻辑。
- `product-specific`：经确认属于产品外壳或主机能力，不应共享业务实现。
- `blocked`：缺少协议、权限、缓存或长任务基础设施，暂不能安全切换。

任何 `shared-ready`、`duplicated`、`blocked` 项都不能计入最终收口完成。

## 产品边界

| 区域 | Core / Pro | Go | 共享原则 |
| --- | --- | --- | --- |
| 应用启动与服务宿主 | 启动本地数据库、Worker 与远程服务 | 恢复远程连接 | `product-specific` |
| 连接与凭据 | 配置监听、TLS、密码、设备 | 输入地址与密码、保存设备凭据 | `product-specific`，共用协议模型 |
| 资料库、阅读器、订阅、运行状态 | 本地 gateway | 远程 gateway | UI 与状态模型必须 `shared-live` |
| 设置 | 主机能力完整 | 按服务端 capability 和设备 scope 展示 | 共用页面；主机专属 section 由 capability 注入 |
| 数据访问 | 直接 SQLite / 本地服务 | HTTPS API / 缓存 | gateway 不同，Contract 相同 |

## 功能矩阵

| ID | 模块 | 具体功能 | 当前状态 | 权限 | 断连行为 |
| --- | --- | --- | --- | --- | --- |
| SHELL-01 | 窗口 | 三栏结构稳定，选择文章不重建根视图 | shared-live | readLibrary | 保留最后数据 |
| SHELL-02 | 窗口 | 左栏 180–360 pt、中栏 280–640 pt 可拖动 | shared-live | readLibrary | 不受影响 |
| SHELL-03 | 窗口 | 窗口、侧栏显示状态恢复 | shared-live | readLibrary | 不受影响 |
| SHELL-04 | 外壳 | Core 服务宿主、Go 连接与产品导航 | product-specific | — | 显示重连入口 |
| LIB-01 | 左栏 | 问题中心红/黄/绿入口 | shared-live | manageOperations | 最后状态+过期标记 |
| LIB-02 | 左栏 | 全部、待处理、已导出与内容类型入口 | shared-live | readLibrary | 使用缓存 |
| LIB-03 | 左栏 | 文件夹/订阅树、未读/全部双计数 | shared-live | readLibrary | 使用缓存+数据时间 |
| LIB-04 | 左栏 | 展开状态持久化 | shared-live | readLibrary | 本地持久化 |
| LIB-05 | 左栏 | 添加源、文件夹、OPML 导入 | shared-live | manageSources | 禁用 |
| LIB-06 | 左栏 | 刷新、全部已读、重命名、删除 | shared-live | 按动作 | 仅已读可排队 |
| LIB-07 | 左栏 | 抓取、全文、处理策略和历史回填 | shared-live | manageSources/runProcessing | 禁用 |
| LIST-01 | 列表 | 标题、来源、日期、摘要、未读、评分、平台标签 | shared-live | readLibrary | 使用缓存 |
| LIST-02 | 列表 | 搜索、防抖、焦点管理 | shared-live | readLibrary | 搜索缓存范围 |
| LIST-03 | 列表 | 评分、未读、星标、处理完成度筛选 | shared-live | readLibrary | 使用缓存 |
| LIST-04 | 列表 | 排序、密度和显示偏好 | shared-live | readLibrary | 本地持久化 |
| LIST-05 | 列表 | 分页、乱序保护、重试和空状态 | shared-live | readLibrary | 缓存到底后提示离线 |
| LIST-06 | 列表 | 自动已读与所有计数同步 | shared-live | updateReadingState | 乐观更新并排队 |
| LIST-07 | 列表 | 单篇右键动作、当前范围全部已读 | shared-live | 按动作 | 仅阅读状态可排队 |
| READ-01 | 阅读 | 标题、来源、作者、日期、评分和原文链接 | shared-live | readLibrary | 使用缓存 |
| READ-02 | 阅读 | 星标、已读、分享、处理、Aa 设置 | shared-live | 按动作 | 星标/已读可排队 |
| READ-03 | 阅读 | 原文/译文跨文章和重启记忆 | shared-live | readLibrary | 本地持久化 |
| READ-04 | 阅读 | 音视频原文/译文/转录标签和安全回退 | shared-live | readLibrary | 已缓存正文可读 |
| READ-05 | 阅读 | Markdown、Frontmatter、链接、代码、多图 | shared-live | readLibrary | 已缓存正文与图片 |
| READ-06 | 阅读 | 音频、YouTube、Bilibili、播放速度 | shared-live | readLibrary | 时效 URL 不保证离线 |
| READ-07 | 阅读 | 上下篇、分享和强制导出 | shared-live | readLibrary/manageExports | 导出禁用 |
| READ-08 | 阅读 | 字体、字号、间距、宽度、缩放和元信息 | shared-live | readLibrary | 本地持久化 |
| READ-09 | 阅读 | J/K/S/空格/V/E/F/? 快捷键 | shared-live | 按动作 | 可用动作继续工作 |
| SRC-01 | 源管理 | 分组、启停、同步和刷新状态 | shared-live | manageSources/runProcessing | 缓存只读 |
| SRC-02 | 源管理 | 添加、识别、OPML 导入导出 | shared-live | manageSources | 禁用 |
| SRC-03 | 源管理 | 文件夹新建、重命名、删除 | shared-live | manageSources | 禁用 |
| SRC-04 | 源管理 | 抓取频率、全文模式、保留量 | shared-live | manageSources | 禁用 |
| SRC-05 | 源管理 | 处理管线和历史回填 | shared-live | runProcessing | 禁用 |
| OPS-01 | 看板 | 队列、扫描阶段、Worker 状态 | shared-live | manageOperations | 最后状态+过期标记 |
| OPS-02 | 看板 | 当前任务和进度 | shared-live | manageOperations | 标记失联 |
| OPS-03 | 看板 | 自动处理失败重试/忽略 | shared-live | manageOperations/runProcessing | 禁用 |
| OPS-04 | 看板 | 全文、源和账号授权问题 | shared-live | manageOperations/manageAuthentication | 最后状态+过期标记 |
| OPS-05 | 看板 | 手动处理历史 | shared-live | manageOperations | 使用缓存 |
| OPS-06 | 看板 | 源健康、问题源和单源重试 | shared-live | manageOperations/runProcessing | 缓存只读 |
| OPS-07 | 看板 | 内容、未读、星标、全文、AI、数据库统计 | shared-live | manageOperations | 使用缓存+数据时间 |
| SET-01 | 设置 | 导航、分组和模块扩展 | shared-live | 按页面 | — |
| SET-02 | 设置 | 通用：自动刷新、间隔、代理 | shared-live | administrator | 禁用写入 |
| SET-03 | 设置 | 阅读器与列表外观 | shared-live | reader | Go 本地保存 |
| SET-04 | 设置 | LLM 模型、密钥和模型检测 | shared-live | administrator | 禁用写入 |
| SET-05 | 设置 | 依赖状态、检测、安装、升级和路径 | shared-live | administrator | Go 路径只读，主机编辑 |
| SET-06 | 设置 | 功能开关、多平台订阅和全文提取 | shared-live | administrator | 禁用写入 |
| SET-07 | 设置 | AI 处理开关和提示词 | shared-live | administrator | 禁用写入 |
| SET-08 | 设置 | 导出平台和规则 | shared-live | administrator | 服务端路径只读 |
| SET-09 | 设置 | 清理、备份、恢复和回收站 | shared-live | administrator | 禁用写入 |
| SET-10 | Core | 远程服务、TLS、密码和设备 | product-specific | host-only | Go 永不显示 |
| SET-11 | Pro | 微信公众号订阅配置 | product-specific | host-only | Go 只见健康状态 |
| SET-12 | Go | 连接、安全和本机缓存 | product-specific | local | 不写回服务端 |

## 数据与离线基础设施

| ID | 能力 | 当前状态 | 目标 |
| --- | --- | --- | --- |
| DATA-01 | 已读/星标乐观更新和失败回滚 | shared-live | 断连可排队，服务器确认后收敛 |
| DATA-02 | 单篇处理状态 | shared-live | 一个集中状态源，活动时 1 秒内更新 |
| DATA-03 | 历史回填、源同步和全文重抓 | shared-live | `202 + jobID`，支持进度、取消和结果 |
| DATA-04 | 页面数据新鲜度 | shared-live | SQLite 单调 revision 经 API 驱动资料库、源和看板刷新 |
| OFF-01 | 连接凭据 | product-specific | 安全持久化，断连不清除 |
| OFF-02 | 最近列表和正文缓存 | shared-live | 最近列表和最多 500 篇正文，最后有效版本 |
| OFF-03 | 离线阅读状态写回 | shared-live | 仅已读/星标，按目标状态去重重放 |
| OFF-04 | 自动重连和增量同步 | shared-live | 5/10/20/30 秒退避重连；重连后 revision 定向刷新 |

## 每项验收要求

- 代码：Core 与 Go 的页面类型来自同一个共享模块，产品壳和 gateway 除外。
- 编译：Core、Pro、Go macOS、Go iOS 均可构建。
- UI：使用同一批文章、订阅源、失败任务和设置完成双端对照。
- 数据：每个写操作验证成功、失败、超时、重复提交和重连后的权威状态。
- 权限：Reader、Operator、Administrator 三种设备都验证可见性和服务端拒绝。
- 断连：不得把网络错误显示成真实空列表或健康状态。

## 收口与删除门槛

1. 本矩阵进入版本控制，并随每次迁移更新。
2. 权限扩展为 Reader / Operator / Administrator，主机专属动作不可由 Go 获得。
3. 长任务统一为异步 Job，并集中刷新运行状态。
4. Go 建立最后有效数据缓存与自动重连。
5. Go macOS 从 `ReadBoardCoreSnapshot` 逐模块切换到 `ReadBoardFeatures`。
6. Core 与 Go 全部验收通过后，删除 Go 中的数据库、Worker、抓取器、设置页和其他快照实现。

当前活动代码路径：Core / Pro 与 Go macOS 均由 `ReadBoardDesktopMainFeatureView` 组合；Go 工程已移除 `ReadBoardCoreSnapshot` 和旧 `ReadBoardSharedUI` 产品、链接依赖及源码目录。产品仓库只保留连接壳、离线缓存和远程 gateway。

删除 `ReadBoardCoreSnapshot` 前，本文件不得再有 `duplicated`、`blocked` 或 `shared-ready` 项。
