import Foundation

// MARK: - whisper 模型自动下载
// 模型缺失时从 huggingface 下载 ggml-medium.bin 到 ~/tools/whisper/models/，带进度回调。

@MainActor
final class ModelDownloader: ObservableObject {
    static let shared = ModelDownloader()

    @Published var isDownloading = false
    @Published var progress: Double = 0       // 0~1，-1 = 未知大小
    @Published var statusText = ""
    @Published var errorMessage: String?

    private let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!
    private let modelPath = NSHomeDirectory() + "/tools/whisper/models/ggml-medium.bin"

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
            try? FileManager.default.removeItem(atPath: tmpPath)

            // 后台 session 下载，URLSession 自身管理进度
            let (asyncBytes, resp) = try await URLSession.shared.bytes(from: modelURL)
            let total = resp.expectedContentLength   // -1 = 未知
            FileManager.default.createFile(atPath: tmpPath, contents: nil)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tmpPath))
            defer { try? handle.close() }
            var written: Int64 = 0
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
            try FileManager.default.moveItem(atPath: tmpPath, toPath: modelPath)
            progress = 1
            statusText = "下载完成"
        } catch {
            errorMessage = "模型下载失败：\(error.localizedDescription)"
            statusText = "下载失败"
        }
    }
}
