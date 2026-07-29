import Foundation

// MARK: - 依赖路径配置（通用软件原则：不硬编码本机路径）
// 优先级：用户在设置页指定的路径（UserDefaults）→ PATH 探测（which）→ 常见安装位置。
// 任何一项都不假设用户机器和我一样——开箱无依赖也可运行核心功能，转录/全文按需配置。

public enum DependencyPaths {

    enum Kind: String, CaseIterable, Identifiable {
        case whisperCLI, ffmpeg, ytdlp, node, whisperModel
        case defuddleEngine
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .whisperCLI: return "whisper-cli"
            case .ffmpeg: return "ffmpeg"
            case .ytdlp: return "yt-dlp"
            case .node: return "node"
            case .whisperModel: return "whisper 模型文件"
            case .defuddleEngine: return "defuddle（正文提取引擎）"
            }
        }

        /// PATH 探测用的可执行名
        var executableName: String? {
            switch self {
            case .whisperCLI: return "whisper-cli"
            case .ffmpeg: return "ffmpeg"
            case .ytdlp: return "yt-dlp"
            case .node: return "node"
            case .whisperModel: return nil
            case .defuddleEngine: return nil
            }
        }

        /// 是否「随 App 打包的资源文件」（不探测 PATH，优先从 Bundle 定位）
        var isEngineFile: Bool {
            switch self { case .defuddleEngine: return true; default: return false }
        }

        /// 常见安装位置（PATH 探测不到时的兜底候选）
        var commonPaths: [String] {
            let home = NSHomeDirectory()
            switch self {
            case .whisperCLI:
                return ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
            case .ffmpeg:
                return ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            case .ytdlp:
                return ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp",
                        home + "/.workbuddy/binaries/python/versions/3.13.12/bin/yt-dlp"]
            case .node:
                return ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            case .whisperModel:
                return Self.scanWhisperModels()
            case .defuddleEngine:
                // fetch_engine.js 脚本路径（非 node_modules/defuddle 目录——cliPath 需要具体的 .js 文件）
                return AppResourceLocator.existingURL("engine/fetch_engine.js")
                    .map { [$0.path] } ?? []
            }
        }

        var defaultsKey: String { "dep.path.\(rawValue)" }

        /// 扫描所有 whisper 模型文件（ggml-*.bin），按文件名去重
        private static func scanWhisperModels() -> [String] {
            let home = NSHomeDirectory()
            let searchDirs = [
                AppResourceLocator.modelsDirectory.path,
                home + "/tools/whisper/models",
                home + "/models",
                home + "/.cache/whisper",
            ]
            let standardNames = [
                "ggml-medium.bin", "ggml-small.bin",
                "ggml-tiny.bin", "ggml-large-v3.bin",
            ]
            let fm = FileManager.default
            var seen: Set<String> = []
            var found: [String] = []
            for dir in searchDirs {
                guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for f in files where f.hasPrefix("ggml-") && f.hasSuffix(".bin") {
                    let name = (f as NSString).lastPathComponent
                    guard !seen.contains(name) else { continue }
                    seen.insert(name)
                    found.append(dir + "/" + f)
                }
            }
            // 即使全新机器尚未下载模型，也要提供稳定候选位置供设置页展示。
            // resolve() 会在返回前检查文件是否真实存在，不会把候选误判为已安装。
            let installed = found.sorted()
            var candidates = installed
            for dir in searchDirs {
                for name in standardNames {
                    let path = dir + "/" + name
                    if seen.insert(path).inserted { candidates.append(path) }
                }
            }
            return candidates
        }
    }

    /// 用户配置了路径但文件已不存在（brew 升级/卸载后路径失效）——设置页据此告警
    static func isCustomStale(_ kind: Kind) -> Bool {
        guard let custom = UserDefaults.standard.string(forKey: kind.defaultsKey),
              !custom.isEmpty else { return false }
        return !FileManager.default.fileExists(atPath: custom)
    }

    /// 解析某依赖的可用路径：用户配置 > PATH 探测 > 常见位置。都不存在返回 nil。
    static func resolve(_ kind: Kind) -> String? {
        let fm = FileManager.default
        // 1. 用户显式配置
        if let custom = UserDefaults.standard.string(forKey: kind.defaultsKey),
           !custom.isEmpty, fm.fileExists(atPath: custom) {
            return custom
        }
        // 2. PATH 探测
        if let exe = kind.executableName, let found = which(exe) {
            return found
        }
        // 3. 常见位置
        for p in kind.commonPaths where fm.fileExists(atPath: p) {
            return p
        }
        return nil
    }

    /// 当前生效路径（供设置页展示；可能为 nil 表示未找到）
    static func current(_ kind: Kind) -> (path: String?, isCustom: Bool) {
        if let custom = UserDefaults.standard.string(forKey: kind.defaultsKey), !custom.isEmpty {
            return (custom, true)
        }
        return (resolve(kind), false)
    }

    /// 保存用户自定义路径（空串 = 清除自定义，回到自动探测）
    static func setCustom(_ kind: Kind, _ path: String) {
        let d = UserDefaults.standard
        if path.isEmpty { d.removeObject(forKey: kind.defaultsKey) }
        else { d.set(path, forKey: kind.defaultsKey) }
    }

    /// which 探测（走 login shell 的 PATH，GUI App 的 PATH 通常不全）
    private static func which(_ name: String) -> String? {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which \(name) 2>/dev/null"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus == 0 && !out.isEmpty) ? out : nil
    }
}
