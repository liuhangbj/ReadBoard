# 非订阅收件箱架构

## 数据归属

- 收件箱继续复用 `content`，不建立第二套文章表。
- `source_id` 保持为真实订阅源外键；收件箱条目为 `NULL`，不创建虚假订阅源。
- `ingest_origin='inbox'` 标识入库来源，`ctype` 继续使用 `article`、`podcast`、`video`。
- `ingest_request_id` 提供系统分享和远程重试的幂等性；规范化 URL 提供第二层去重。
- 收件箱是虚拟资料库集合，可以统一复用已读、星标、正文、AI 结果、媒体播放、导出和删除能力。

## 契约和接口

共享契约为 `InboxGateway`：

- `configuration()` / `updateConfiguration()`：读写默认目标。
- `importURL()`：接收幂等请求，返回新建或已存在的内容 ID。
- `applyCurrentTargetsToExistingItems()`：显式重设历史收件箱条目的处理目标。

远程中间层对应：

- `GET /api/v1/inbox/configuration`
- `POST /api/v1/inbox/configuration`
- `POST /api/v1/inbox/import`
- `POST /api/v1/inbox/retarget`

本机 Core/Pro 注入 `LocalInboxGateway`，Go 注入 `RemoteInboxGateway`；共享前端只依赖契约。

## Pipeline

1. URL 规范化并识别文章、播客或视频。
2. 轻量读取页面标题、作者、封面、摘要、规范链接和媒体地址；直接媒体链接不预下载文件。
3. 写入 `content`，同时把 AI 目标固化到 `auto_*` 字段。
4. 正文目标和自动导出许可固化在 `meta`，供失败恢复与导出队列判断。
5. 正文/字幕立即尝试一次；失败后进入原有全文恢复调度。
6. 评分、摘要、翻译、转录由原有 Worker 按条目目标执行。
7. 导出复用 ready 队列；收件箱默认禁止自动导出，手动单篇导出不受影响。

Go 的系统分享请求会先写入本机暂存队列；远程服务断连时保留，恢复连接后按同一 `requestID` 自动补送。

## 设置

- 文章、播客、视频分别设置：正文/字幕、AI评分、AI摘要、AI翻译；媒体另有 AI转录。
- 新内容是否保持未读。
- 是否允许自动导出规则处理收件箱内容（默认关闭）。
- “应用当前目标”是历史回填的显式动作，避免修改默认值后意外产生大批 AI 请求。

去重行为、虚拟集合位置和全局保留策略采用固定复用规则，不增加容易产生歧义的开关。
