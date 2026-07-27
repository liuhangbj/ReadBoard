import Foundation

// MARK: - 依赖检测（按功能分组）
// 启动时 / 进入依赖页时检查各外部依赖，缺失的给出安装引导。
// 模型文件 / 引擎文件缺失可自动下载(见 ModelDownloader)；whisper-cli/ffmpeg/yt-dlp 需 brew/手动安装。
//
// 通用原则：路径优先级 = 用户在设置页指定的路径（UserDefaults）> 自动探测（PATH / Bundle 资源 / 常见位置）。
// 任何项都不假设用户机器与我一致——开箱无依赖也能跑核心功能，转录 / 全文按需配置。

/// 单一依赖项（一个可执行 / 一个文件）
public struct DependencyItem: Identifiable, Equatable {
    public let id: String                 // DependencyPaths.Kind.rawValue
    let displayName: String
    let path: String                     // 当前生效路径，未找到为「未找到」
    let installed: Bool
    /// 一键安装命令（brew / npm 类）；nil 表示走自动下载或无需安装
    let installCommand: String?
    /// 安装提示文字
    let installHint: String
}

/// 一个功能所需的全部依赖 + 该项是否可用（全部依赖在位）
public struct DependencyGroup: Identifiable {
    public let id: String
    let title: String
    let icon: String
    let description: String
    var items: [DependencyItem]
    var ready: Bool { items.allSatisfy { $0.installed } }
}

public final class DependencyChecker: @unchecked Sendable {
    static let shared = DependencyChecker()

    private init() {}

    // MARK: - 各组

    /// 全文提取功能：defuddle 本地引擎（fetch_engine.js）+ 运行它的 node
    func fulltextGroup() -> DependencyGroup {
        let items = [
            makeItem(.defuddleEngine,
                     display: "defuddle 引擎（fetch_engine.js）",
                     cmd: nil,
                     hint: "随 App 打包在 Contents/Resources/engine；如需外置可在此指定路径"),
            makeItem(.node,
                     display: "node（运行引擎）",
                     cmd: "brew install node",
                     hint: "brew install node，或在下方指定路径"),
        ]
        return DependencyGroup(
            id: "fulltext",
            title: "全文提取（defuddle）",
            icon: "doc.text.magnifyingglass",
            description: "本地提取文章正文转 Markdown。缺失时自动 fallback 到 Jina Reader 云端渲染。",
            items: items)
    }

    /// 转录功能：whisper-cli + ffmpeg + yt-dlp + 模型
    func transcribeGroup() -> DependencyGroup {
        let items = [
            makeItem(.whisperCLI, display: "whisper-cli（转写引擎）",
                     cmd: "brew install whisper-cpp", hint: "brew install whisper-cpp，或在下方指定路径"),
            makeItem(.ffmpeg, display: "ffmpeg（音频转码）",
                     cmd: "brew install ffmpeg", hint: "brew install ffmpeg，或在下方指定路径"),
            makeItem(.ytdlp, display: "yt-dlp（视频抽音频）",
                     cmd: "brew install yt-dlp", hint: "brew install yt-dlp（或 pip3 install yt-dlp）"),
            makeItem(.whisperModel, display: "whisper 模型 ggml-medium.bin（1.4G）",
                     cmd: nil, hint: "可自动下载，或在下方指定已有模型文件"),
        ]
        return DependencyGroup(
            id: "transcribe",
            title: "转录（播客 / 视频转写）",
            icon: "waveform",
            description: "把音频 / 视频转成文字稿。四项全部到位转录功能才可用。",
            items: items)
    }

    /// 全部功能组
    func checkAllGroups() -> [DependencyGroup] {
        [fulltextGroup(), transcribeGroup()]
    }

    /// 缺失的依赖项（跨全部组）
    func missing() -> [DependencyItem] {
        checkAllGroups().flatMap { $0.items }.filter { !$0.installed }
    }

    /// 转录是否可用（旧 API 兼容，PipelineWorker 等仍调用）
    var transcribeReady: Bool { transcribeGroup().ready }

    /// 模型是否缺失（可自动下载）
    var modelMissing: Bool { DependencyPaths.resolve(.whisperModel) == nil }

    var modelPathString: String { DependencyPaths.resolve(.whisperModel) ?? "未配置" }

    // MARK: - 私有

    private func makeItem(_ kind: DependencyPaths.Kind, display: String,
                          cmd: String?, hint: String) -> DependencyItem {
        let resolved = DependencyPaths.resolve(kind)
        return DependencyItem(
            id: kind.rawValue, displayName: display,
            path: resolved ?? "未找到",
            installed: resolved != nil,
            installCommand: cmd, installHint: hint)
    }
}
