import Foundation

// MARK: - 转录依赖检测
// 启动时检查 whisper 转录链路的 4 个外部依赖，缺失的给出安装引导。
// 模型文件缺失可自动下载(见 ModelDownloader)；whisper-cli/ffmpeg/yt-dlp 需 brew/手动安装。

struct TranscribeDependency: Identifiable {
    let id: String          // whisper-cli / ffmpeg / yt-dlp / model
    let displayName: String
    let path: String
    let installed: Bool
    /// 一键安装命令（brew 类）；模型走自动下载故为 nil
    let installCommand: String?
    /// 安装提示文字
    let installHint: String
}

final class DependencyChecker: @unchecked Sendable {
    static let shared = DependencyChecker()

    private let whisperBin = "/opt/homebrew/bin/whisper-cli"
    private let ffmpegBin = "/opt/homebrew/bin/ffmpeg"
    private let ytdlpBin = NSHomeDirectory() + "/.workbuddy/binaries/python/versions/3.13.12/bin/yt-dlp"
    private let modelPath = NSHomeDirectory() + "/tools/whisper/models/ggml-medium.bin"

    private init() {}

    /// 检测全部依赖，返回各项状态
    func checkAll() -> [TranscribeDependency] {
        let fm = FileManager.default
        return [
            TranscribeDependency(
                id: "whisper-cli", displayName: "whisper-cli（转写引擎）",
                path: whisperBin, installed: fm.fileExists(atPath: whisperBin),
                installCommand: "brew install whisper-cpp",
                installHint: "brew install whisper-cpp"),
            TranscribeDependency(
                id: "ffmpeg", displayName: "ffmpeg（音频转码）",
                path: ffmpegBin, installed: fm.fileExists(atPath: ffmpegBin),
                installCommand: "brew install ffmpeg",
                installHint: "brew install ffmpeg"),
            TranscribeDependency(
                id: "yt-dlp", displayName: "yt-dlp（视频抽音频）",
                path: ytdlpBin, installed: fm.fileExists(atPath: ytdlpBin),
                installCommand: "pip3 install yt-dlp",
                installHint: "pip3 install yt-dlp（或 brew install yt-dlp）"),
            TranscribeDependency(
                id: "model", displayName: "whisper 模型 ggml-medium.bin（1.4G）",
                path: modelPath, installed: fm.fileExists(atPath: modelPath),
                installCommand: nil,
                installHint: "可自动下载，点下方按钮"),
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
        !FileManager.default.fileExists(atPath: modelPath)
    }

    var modelPathString: String { modelPath }
}
