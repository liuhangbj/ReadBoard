import Foundation

// MARK: - 转录依赖检测
// 启动时检查 whisper 转录链路的 4 个外部依赖，缺失的给出安装引导。
// 模型文件缺失可自动下载(见 ModelDownloader)；whisper-cli/ffmpeg/yt-dlp 需 brew/手动安装。

public struct TranscribeDependency: Identifiable {
    public let id: String          // whisper-cli / ffmpeg / yt-dlp / model
    let displayName: String
    let path: String
    let installed: Bool
    /// 一键安装命令（brew 类）；模型走自动下载故为 nil
    let installCommand: String?
    /// 安装提示文字
    let installHint: String
}

public final class DependencyChecker: @unchecked Sendable {
    static let shared = DependencyChecker()

    private init() {}

    /// 检测全部依赖，返回各项状态（路径走 DependencyPaths 解析：用户配置 > PATH > 常见位置）
    func checkAll() -> [TranscribeDependency] {
        func dep(_ kind: DependencyPaths.Kind, display: String, cmd: String?, hint: String) -> TranscribeDependency {
            let (path, _) = DependencyPaths.current(kind)
            let resolved = DependencyPaths.resolve(kind)
            return TranscribeDependency(
                id: kind.rawValue, displayName: display,
                path: path ?? "未找到",
                installed: resolved != nil,
                installCommand: cmd, installHint: hint)
        }
        return [
            dep(.whisperCLI, display: "whisper-cli（转写引擎）",
                cmd: "brew install whisper-cpp", hint: "brew install whisper-cpp，或在下方指定路径"),
            dep(.ffmpeg, display: "ffmpeg（音频转码）",
                cmd: "brew install ffmpeg", hint: "brew install ffmpeg，或在下方指定路径"),
            dep(.ytdlp, display: "yt-dlp（视频抽音频）",
                cmd: "brew install yt-dlp", hint: "brew install yt-dlp（或 pip3 install yt-dlp）"),
            dep(.whisperModel, display: "whisper 模型 ggml-medium.bin（1.4G）",
                cmd: nil, hint: "可自动下载，或在下方指定已有模型文件"),
        ]
    }

    /// 缺失的依赖项
    func missing() -> [TranscribeDependency] {
        checkAll().filter { !$0.installed }
    }

    /// 转录是否可用（全部依赖在位）
    var transcribeReady: Bool { missing().isEmpty }

    /// 模型是否缺失（可自动下载）
    var modelMissing: Bool {
        DependencyPaths.resolve(.whisperModel) == nil
    }

    var modelPathString: String { DependencyPaths.resolve(.whisperModel) ?? "未配置" }
}
