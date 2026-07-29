# ReadBoard

ReadBoard 是一个面向人和 AI 的信息整合与加工平台。它把文章、播客和视频等不同来源统一入库，完成全文提取、评分、摘要、翻译和转录，再按规则交付到 Obsidian 或其他下游服务。

## 项目状态

当前为 macOS 开发版本，最低支持 macOS 14。源码使用 Swift 6、SwiftUI 和 Swift Package Manager 构建。

## 本地构建

```bash
cd App/ReadBoard
Scripts/build_and_run.sh
```

脚本会构建完整 App，并默认安装到：

```text
~/Applications/ReadBoard.app
```

调试构建：

```bash
cd App/ReadBoard
Scripts/build_and_run.sh --debug
```

## 测试

涉及数据库的测试必须使用隔离路径，不能指向真实数据库：

```bash
tmp_dir="$(mktemp -d)"
cd App/ReadBoard
READBOARD_DB="$tmp_dir/readboard.db" swift test
```

## 本地数据

真实数据库、凭证、备份、模型和编译产物都不进入 Git。运行数据位于：

```text
~/Library/Application Support/ReadBoard/
```

详细约定见 [docs/data-storage.md](docs/data-storage.md)。

## 目录

- `App/ReadBoard`：macOS App、资源、测试和打包脚本。
- `Scripts/Maintenance`：只在明确指定数据库后运行的数据维护脚本。
- `docs`：架构、数据目录和发布说明。
- `.github/workflows`：持续集成与版本发布工作流。

## 发布

本地构建采用 ad-hoc 签名，仅供开发使用。面向其他用户发布时需要 Developer ID 签名、Apple 公证和 GitHub Release。详见 [docs/release.md](docs/release.md)。
