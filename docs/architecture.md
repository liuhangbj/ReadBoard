# ReadBoard 架构

ReadBoard 的核心不是 RSS 阅读器，而是信息加工中台：

1. 输入层连接文章、播客、视频及未来的其他平台。
2. 存储层把不同来源统一为内容记录。
3. 内容处理引擎执行全文提取、评分、摘要、翻译和转录。
4. 交付层按规则输出到 Obsidian、Webhook 及未来的平台。
5. 未来的 MCP 服务在统一内容库上提供 BM25 等检索能力。

当前 macOS App 位于 `App/ReadBoard`。未来需要让 App 和 MCP 服务共享模型与查询能力时，再提取 `Packages/ReadBoardCore`；在此之前不为假想复用增加模块复杂度。

数据库结构迁移只有一份权威来源：

```text
Sources/ReadBoard/Resources/migrations/
```

SwiftPM 构建时将其装入 App 资源，新数据库从基线迁移直接建立到当前版本。
