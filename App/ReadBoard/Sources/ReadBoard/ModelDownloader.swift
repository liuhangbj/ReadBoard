import Foundation

// MARK: - whisper 模型自动下载
// 模型缺失时从 huggingface 下载 ggml-medium.bin 到 ~/tools/whisper/models/，带进度回调。

@MainActor
public final class ModelDownloader: ObservableObject {
    static let shared = ModelDownloader()

    @Published var isDownloading = false
    @Published var progress: Double = 0       // 0~1，-1 = 未知大小
    @Published var statusText = ""
    @Published var errorMessage: String?

    private let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!
    /// 下载目标路径：用户自定义的模型路径优先，否则默认 ~/tools/whisper/models/
    private var modelPath: String {
        if let custom = UserDefaults.standard.string(forKey: DependencyPaths.Kind.whisperModel.defaultsKey),
           !custom.isEmpty {
            return custom
        }
        return NSHomeDirectory() + "/tools/whisper/models/ggml-medium.bin"
    }

    private init() {}

    /// 下载模型（已在位则直接成功）。完成回调 success。
    func download() async {
        guard !isDownloading else { return }
        if FileManager.default.fileExists(atPath: modelPath) {
            statusText = "模型已存在"
            return
        }
        isDownloading = true
        errorMessage = nil
        progress = 0
        statusText = "准备下载…"
        defer { isDownloading = false }

        do {
            let dir = (modelPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            let tmpPath = modelPath + ".download"
            // 断点续传：已有部分文件则从断点接着下（Range 头），不从头再来
            var resumeFrom: Int64 = 0
            if let attrs = try? FileManager.default.attributesOfItem(atPath: tmpPath),
               let size = attrs[.size] as? Int64, size > 0 {
                resumeFrom = size
            }

            var req = URLRequest(url: modelURL)
            if resumeFrom > 0 {
                req.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
                statusText = String(format: "从 %.0f MB 续传…", Double(resumeFrom) / 1_000_000)
            }
            let (asyncBytes, resp) = try await URLSession.shared.bytes(for: req)
            let http = resp as? HTTPURLResponse
            // 服务器不支持 Range（200 而非 206）→ 从头下，清掉旧部分文件
            let serverResumed = resumeFrom > 0 && http?.statusCode == 206
            if resumeFrom > 0 && http?.statusCode == 200 {
                resumeFrom = 0   // 服务端忽略 Range，重来
            }
            let bodyLen = resp.expectedContentLength   // 本次响应的长度
            let total: Int64 = serverResumed ? (resumeFrom + max(bodyLen, 0)) : bodyLen   // -1 = 未知

            if !serverResumed {
                FileManager.default.createFile(atPath: tmpPath, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tmpPath))
            defer { try? handle.close() }
            if serverResumed { try handle.seekToEnd() }
            var written: Int64 = resumeFrom
            for try await byte in asyncBytes {
                try handle.write(contentsOf: [byte])
                written += 1
                if written % (512 * 1024) == 0 {   // 每 512KB 刷一次进度
                    if total > 0 {
                        self.progress = Double(written) / Double(total)
                        self.statusText = String(format: "下载中 %.0f / %.0f MB",
                            Double(written) / 1_000_000, Double(total) / 1_000_000)
                    } else {
                        self.progress = -1
                        self.statusText = String(format: "下载中 %.0f MB", Double(written) / 1_000_000)
                    }
                }
            }
            // 完整性校验：Content-Length 已知时核对最终文件大小（网络中断静默截断
            // 会产生"能下载完但 whisper 加载即崩"的残模型，不如当场报错误删重下）
            if total > 0,
               let finalSize = (try? FileManager.default.attributesOfItem(atPath: tmpPath))?[.size] as? Int64,
               finalSize != total {
                try? FileManager.default.removeItem(atPath: tmpPath)
                throw DownloadError.sizeMismatch(expected: total, got: finalSize)
            }
            try FileManager.default.moveItem(atPath: tmpPath, toPath: modelPath)
            progress = 1
            statusText = "下载完成"
        } catch {
            errorMessage = "模型下载失败：\(error.localizedDescription)（重开会从断点续传）"
            statusText = "下载失败"
        }
    }

    enum DownloadError: Error, LocalizedError {
        case sizeMismatch(expected: Int64, got: Int64)
        var errorDescription: String? {
            switch self {
            case .sizeMismatch(let e, let g):
                return String(format: "文件不完整（期望 %.0f MB，实际 %.0f MB），已删除请重试",
                              Double(e) / 1_000_000, Double(g) / 1_000_000)
            }
        }
    }
}
