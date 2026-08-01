import Foundation

/// 真实落盘 Tracer——API 与旧 stub 完全一致（i/d/w/e/perf/mb/内存采样），所有既有调用点零改动。
/// 目的：给「切原文/译文卡顿」提供**真实耗时数据**——之前 stub 版把全部 Trace 调用吞进 /dev/null，
/// 导致埋好的 perf 计时全没记录，排查只能猜。此版写到固定文件，可直接 tail/读文件定位耗时。
enum Trace {
    /// 日志文件（用户目录，稳定可 tail）
    static var logFileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(AppResourceLocator.applicationSupportDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("readboard.log")
    }

    private static let queue = DispatchQueue(label: "trace", qos: .utility)
    /// ISO8601DateFormatter 非 Sendable，但仅在串行 queue 内使用——加 nonisolated(unsafe) 绕过 Swift 6 检查。
    private nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func write(_ level: String, _ msg: String, category: String) {
        let line = "\(iso.string(from: Date())) [\(level)] [\(category)] \(msg)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let url = logFileURL
            if FileManager.default.fileExists(atPath: url.path),
               let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func i(_ msg: String, category: String = "app") { write("I", msg, category: category) }
    static func d(_ msg: String, category: String = "app") { write("D", msg, category: category) }
    static func w(_ msg: String, category: String = "app") { write("W", msg, category: category) }
    static func e(_ msg: String, category: String = "app") { write("E", msg, category: category) }

    /// 性能埋点：从 start 到现在的毫秒数
    static func perf(_ label: String, start: Date, category: String = "perf", extra: String = "") {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        write("PERF", "\(label) 用时=\(ms)ms \(extra)", category: category)
    }

    /// 当前进程常驻内存（MB）
    static func mb() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kret = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kret == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }

    /// 内存采样定时器——仅在串行 queue 与 start/stop 间访问，用 nonisolated(unsafe) 绕过 Swift 6 全局可变检查。
    private nonisolated(unsafe) static var memTimer: DispatchSourceTimer?
    static func startMemorySampler(category: String = "mem") {
        stopMemorySampler(category: category)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2.0)
        t.setEventHandler { write("MEM", "mem=\(mb())MB", category: category) }
        t.resume()
        memTimer = t
    }
    static func stopMemorySampler(category: String = "mem") {
        memTimer?.cancel(); memTimer = nil
    }
}
