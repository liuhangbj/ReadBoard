import Foundation

/// 处理服务统一使用第一个非空音频地址。
enum MediaAudioURLResolver {
    nonisolated static func preferred(_ candidates: String?...) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
