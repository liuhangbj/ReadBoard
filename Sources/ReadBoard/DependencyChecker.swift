import Foundation

// MARK: - 依赖检测（按功能分组）
// 启动时 / 进入依赖页时检查各外部依赖，缺失的给出安装引导。
// 模型文件 / 引擎文件缺失可自动下载(见 ModelDownloader)；whisper-cli/ffmpeg/yt-dlp 需 brew/手动安装。
//
// 通用原则：路径优先级 = 用户在设置页指定的路径（UserDefaults）> 自动探测（PATH / Bundle 资源 / 常见位置）。
// 任何项都不假设用户机器与我一致——开箱无依赖也能跑核心功能，转录 / 全文按需配置。

/// 单一依赖项（一个可执行 / 一个文件）
public struct DependencyItem: Identifiable, Equatable {
    public let id: String
    let displayName: String
    let path: String
    let installed: Bool
    let version: String?
    let installCommand: String?
    let upgradeCommand: String?
    let installHint: String
    /// 备选路径（whisper 模型多份时供 UI 下拉选取）
    let alternatePaths: [String]
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

    /// 全文提取功能：defuddle 本地引擎 + 运行它的 node
    func fulltextGroup() -> DependencyGroup {
        let items = [
            makeItem(.defuddleEngine,
                     display: "defuddle（正文提取引擎）",
                     cmd: nil,
                     hint: "该引擎应随 ReadBoard 一同安装；缺失时请重新安装 App"),
            makeItem(.node,
                     display: "node（运行引擎）",
                     cmd: "brew install node",
                     hint: "brew install node，或在下方指定路径"),
        ]
        return DependencyGroup(
            id: "fulltext",
            title: "全文提取（defuddle）",
            icon: "doc.text.magnifyingglass",
            description: "本地提取文章正文转 Markdown。缺失时自动 fallback 到 feed 自带全文或摘要。",
            items: items)
    }

    /// 转录功能：whisper-cli + ffmpeg + yt-dlp + 模型
    func transcribeGroup() -> DependencyGroup {
        let modelPath = DependencyPaths.resolve(.whisperModel)
        let modelDisplay = "whisper 模型（语音转文字模型）"

        let items = [
            makeItem(.whisperCLI, display: "whisper-cli（转写引擎）",
                     cmd: "brew install whisper-cpp", hint: "brew install whisper-cpp，或在下方指定路径"),
            makeItem(.ffmpeg, display: "ffmpeg（音频转码 / 提取）",
                     cmd: "brew install ffmpeg", hint: "brew install ffmpeg，或在下方指定路径"),
            makeItem(.ytdlp, display: "yt-dlp（视频下载）",
                     cmd: "brew install yt-dlp", hint: "brew install yt-dlp（也可 pip3 install yt-dlp）"),
            DependencyItem(
                id: DependencyPaths.Kind.whisperModel.rawValue, displayName: modelDisplay,
                path: modelPath ?? "未找到",
                installed: modelPath != nil,
                version: modelPath != nil ? modelVersion(modelPath!) : nil,
                installCommand: "readboard:model-download",
                upgradeCommand: modelPath != nil ? "readboard:model-redownload" : nil,
                installHint: "可自动下载，或拖入已有模型文件",
                alternatePaths: modelPath != nil ? DependencyPaths.Kind.whisperModel.commonPaths.filter { $0 != modelPath } : []),
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
        let version = resolved != nil ? detectVersion(kind: kind, path: resolved!) : nil
        let upgradeCmd: String? = {
            guard let c = cmd else { return nil }
            if c.hasPrefix("brew install") {
                return c.replacingOccurrences(of: "brew install", with: "brew upgrade")
            }
            if c.hasPrefix("pip install") {
                return c.replacingOccurrences(of: "pip install", with: "pip install --upgrade")
            }
            if c.hasPrefix("cd ") && c.contains("npm install") {
                return c.replacingOccurrences(of: "npm install", with: "npm update")
            }
            return nil
        }()
        return DependencyItem(
            id: kind.rawValue, displayName: display,
            path: resolved ?? "未找到",
            installed: resolved != nil,
            version: version,
            installCommand: cmd,
            upgradeCommand: upgradeCmd,
            installHint: hint,
            alternatePaths: [])
    }

    /// whisper 模型"版本"= ggml-medium · 1483 MB
    private func modelVersion(_ path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return nil }
        let mb = String(format: "%.0f MB", Double(size) / 1_048_576)
        let name = (path as NSString).lastPathComponent
        return "\(name) · \(mb)"
    }

    /// 检测依赖的版本号（--version 或等效命令）
    private func detectVersion(kind: DependencyPaths.Kind, path: String) -> String? {
        let args: [String]
        switch kind {
        case .whisperCLI: args = ["--version"]
        case .ffmpeg:     args = ["-version"]
        case .ytdlp:      args = ["--version"]
        case .node:       args = ["--version"]
        case .defuddleEngine:
            // resolve(.defuddleEngine) 返回 fetch_engine.js 路径（引擎脚本），
            // npm 包版本在 node_modules/defuddle/package.json，反推找到它
            let engineDir = (path as NSString).deletingLastPathComponent
            let pkg = engineDir + "/node_modules/defuddle/package.json"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: pkg)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ver = obj["version"] as? String {
                return "v\(ver)"
            }
            return nil
        default: return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self.extractVersion(out, kind: kind)
    }

    /// 从版本命令输出中提取干净的版本号
    static func extractVersion(_ raw: String, kind: DependencyPaths.Kind) -> String? {
        switch kind {
        case .ffmpeg:
            // "ffmpeg version 8.1.2 Copyright (c) ..." → "8.1.2"
            guard let r = raw.range(of: #"version (\d+\.\d+(\.\d+)?)"#, options: .regularExpression) else { return nil }
            return String(raw[r]).replacingOccurrences(of: "version ", with: "")
        case .whisperCLI:
            // "whisper.cpp v1.7.6..." → "v1.7.6"
            if let r = raw.range(of: #"v?\d+\.\d+(\.\d+)?"#, options: .regularExpression) {
                let v = String(raw[r])
                return v.hasPrefix("v") ? v : "v\(v)"
            }
            return raw
        case .node:
            // "v24.11.1" → already clean
            return raw.trimmingCharacters(in: .whitespaces)
        default:
            // yt-dlp etc: first line, short enough
            let firstLine = raw.components(separatedBy: "\n").first ?? raw
            return firstLine.count <= 40 ? firstLine : String(firstLine.prefix(37)) + "..."
        }
    }
}
