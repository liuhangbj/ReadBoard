import Foundation

// MARK: - whisper 模型自动下载
// 模型缺失时从 huggingface 下载到 Application Support/ReadBoard/models，带进度回调。
// 支持 tiny / small / medium / large-v3 四种模型。

@MainActor
public final class ModelDownloader: ObservableObject {
    static let shared = ModelDownloader()

    @Published var isDownloading = false
    @Published var progress: Double = 0       // 0~1，-1 = 未知大小
    @Published var statusText = ""
    @Published var errorMessage: String?

    /// 可供下载的模型列表
    static let availableModels: [(name: String, displayName: String, approxSize: String, url: String)] = [
        ("tiny",       "ggml-tiny（~75 MB）",       "75 MB",  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin"),
        ("small",      "ggml-small（~466 MB）",      "466 MB", "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"),
        ("medium",     "ggml-medium（~1.5 GB）",     "1.5 GB", "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"),
        ("large-v3",   "ggml-large-v3（~3 GB）",     "3 GB",   "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"),
    ]

    /// 从模型名获取 URL
    static func modelURL(for modelName: String) -> URL? {
        availableModels.first(where: { $0.name == modelName }).map { URL(string: $0.url)! }
    }

    /// 获取某模型的默认下载路径
    static func modelPath(for modelName: String) -> String {
        AppResourceLocator.modelsDirectory
            .appendingPathComponent("ggml-\(modelName).bin").path
    }

    /// 检查模型是否存在，返回实际文件大小（字节），不存在返回 -1
    static func modelExists(name: String, path: String? = nil) -> (exists: Bool, sizeBytes: Int64) {
        let p = path ?? modelPath(for: name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              let size = attrs[.size] as? Int64 else { return (false, -1) }
        return (true, size)
    }

    /// 格式化字节为可读大小
    static func formatSize(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 { return String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
        if bytes >= 1_048_576 { return String(format: "%.0f MB", Double(bytes) / 1_048_576) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    private init() {}

    /// 下载指定模型
    func download(modelName: String = "medium") async {
        guard !isDownloading else { return }
        guard let url = Self.modelURL(for: modelName) else {
            errorMessage = "未知模型：\(modelName)"
            return
        }
        let targetPath = Self.modelPath(for: modelName)

        if FileManager.default.fileExists(atPath: targetPath) {
            statusText = "模型已存在"
            return
        }
        isDownloading = true
        errorMessage = nil
        progress = 0
        statusText = "准备下载…"
        defer { isDownloading = false }

        do {
            let dir = (targetPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            let tmpPath = targetPath + ".download"
            var resumeFrom: Int64 = 0
            if let attrs = try? FileManager.default.attributesOfItem(atPath: tmpPath),
               let size = attrs[.size] as? Int64, size > 0 {
                resumeFrom = size
            }

            var req = URLRequest(url: url)
            if resumeFrom > 0 {
                req.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
                statusText = String(format: "从 %.0f MB 续传…", Double(resumeFrom) / 1_000_000)
            }
            let (asyncBytes, resp) = try await URLSession.shared.bytes(for: req)
            let http = resp as? HTTPURLResponse
            let serverResumed = resumeFrom > 0 && http?.statusCode == 206
            if resumeFrom > 0 && http?.statusCode == 200 {
                resumeFrom = 0
            }
            let bodyLen = resp.expectedContentLength
            let total: Int64 = serverResumed ? (resumeFrom + max(bodyLen, 0)) : bodyLen

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
                if written % (512 * 1024) == 0 {
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
            if total > 0,
               let finalSize = (try? FileManager.default.attributesOfItem(atPath: tmpPath))?[.size] as? Int64,
               finalSize != total {
                try? FileManager.default.removeItem(atPath: tmpPath)
                throw DownloadError.sizeMismatch(expected: total, got: finalSize)
            }
            try FileManager.default.moveItem(atPath: tmpPath, toPath: targetPath)
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
