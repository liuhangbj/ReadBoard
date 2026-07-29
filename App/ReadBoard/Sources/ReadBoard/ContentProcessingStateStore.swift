import Foundation
import SwiftUI

/// 单篇手动内容处理的界面状态。状态按 content id 存在共享 Store 中，
/// ReadingView 因切换文章被重建后仍能恢复“处理中/处理结果”，不会退回空白。
@MainActor
final class ContentProcessingStateStore: ObservableObject {
    struct Entry: Equatable, Sendable {
        let isProcessing: Bool
        let message: String
        let updatedAt: Date
    }

    static let shared = ContentProcessingStateStore()

    @Published private var entries: [Int64: Entry] = [:]

    func state(for contentId: Int64) -> Entry? {
        entries[contentId]
    }

    func begin(contentId: Int64, message: String) {
        set(contentId: contentId, isProcessing: true, message: message)
    }

    func finish(contentId: Int64, message: String) {
        set(contentId: contentId, isProcessing: false, message: message)
    }

    func notice(contentId: Int64, message: String) {
        set(contentId: contentId, isProcessing: false, message: message)
    }

    func clear(contentId: Int64) {
        entries.removeValue(forKey: contentId)
    }

    private func set(contentId: Int64, isProcessing: Bool, message: String) {
        entries[contentId] = Entry(
            isProcessing: isProcessing,
            message: message,
            updatedAt: Date())
        pruneIfNeeded()
    }

    /// 手动任务很少，但长期运行仍限制已完成状态数量；活跃任务永不清理。
    private func pruneIfNeeded() {
        guard entries.count > 128 else { return }
        let removable = entries
            .filter { !$0.value.isProcessing }
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
        for (contentId, _) in removable.prefix(entries.count - 96) {
            entries.removeValue(forKey: contentId)
        }
    }
}
