# ReadBoard 架构

ReadBoard Core 是完整的信息加工服务与本地阅读器，ReadBoard Go 是连接该服务的远程客户端。两者不是两套产品代码：除数据接入和产品能力外，界面、状态模型和交互实现应共用。

## 分层

```text
ReadBoardFeatures（完整功能板块、页面状态和导航）
                  │
ReadBoardUI（设计系统、阅读内核和基础控件）
                  │
ReadBoardContract（稳定的数据与 Gateway 协议）
          ┌───────┴────────┐
          │                │
   Local Gateway      Remote Gateway
   Core 直接读服务      Go 经 HTTPS 访问服务
          │                │
      Core / Pro         ReadBoard Go
```

- `ReadBoardContract`：跨进程传输模型、错误模型和 Gateway 协议，不依赖数据库或界面。
- `ReadBoardUI`：Core 与 Go 共用的设计系统、阅读内核和基础控件，不持有完整产品页面。
- `ReadBoardFeatures`：完整产品页面的唯一源码，只依赖 Contract、ReadBoardUI 和注入的 `ReadBoardFeatureEnvironment`。
- `ReadBoard`：数据库、抓取、内容处理、导出及 Local Gateway；本机继续直接调用，不绕 HTTP。
- `ReadBoardRemote`：HTTPS 传输及 Remote Gateway；不包含产品界面。
- `readboard-pro`：组合 Core、共享 UI 和私有服务能力。
- `readboard-go`：保留连接引导、Remote Gateway 注入、平台壳与打包资源。

## 不可破坏的边界

1. `ReadBoardUI` 和 `ReadBoardFeatures` 不得直接引用 SQLite、HTTP 路由或具体 Gateway 实现。
2. Core 与 Go 的同一页面不得复制实现；差异通过依赖注入、能力声明和插槽表达。
3. Core 本机调用 Local Gateway，Go 调用 Remote Gateway；二者必须返回相同 Contract 类型。
4. Pro 私有功能通过模块/能力注册出现，不在共享页面中散布产品名判断。
5. 新功能必须先进入 `ReadBoardFeatures`；只有连接、平台生命周期或服务端专属逻辑可以留在产品仓库。
6. Go 不复制 Core 页面；它直接编译 ReadBoard 包中的同一份 Feature 源码。仓库独立不等于页面实现独立。

## 迁移状态

共享层现已覆盖资料库导航、固定分类、文件夹与订阅源、搜索与筛选、排序与分页、列表状态、文章详情、Markdown/多图、音视频、阅读版式、读/星标写回、源管理、处理看板、设置导航和问题中心。设置窗口的产品差异通过页面插槽表达，问题中心的状态模型和固定空列表框架只有一份实现。

远程中间层覆盖 profile、资料库、处理、源、授权、导出、配置、管理、维护和依赖任务。依赖安装/更新是服务端白名单异步任务；Go 只能提交、查询和取消，不能在客户端执行服务端命令。HTTP 矩阵同时验证成功、权限、令牌、版本、解码和服务错误。

Go macOS 仍保留 CoreSnapshot 作为完整桌面壳兼容层，以维持已经验证的列宽、快捷键和页面细节；其中设置导航与问题中心已切换到 `ReadBoardFeatures`，不再维护同义实现。后续移除兼容壳必须以两端真实 App 对照验证为前提，不能通过替换成缩水页面来追求目录层面的“完成”。

数据库结构迁移的唯一权威来源仍为：

```text
Sources/ReadBoard/Resources/migrations/
```
