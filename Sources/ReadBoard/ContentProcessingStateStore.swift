import Foundation
import SwiftUI

/// 单篇手动内容处理的界面状态。状态按 content id 存在共享 Store 中，
/// 共享阅读页因切换文章被重建后仍能恢复“处理中/处理结果”，不会退回空白。
@MainActor
final class ContentProcessingStateStore: ObservableObject {
    struct Entry: Identifiable, Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case queued
            case running
            case succeeded
            case failed
        }

        let contentId: Int64
        let title: String
        let operation: String
        let phase: Phase
        let message: String
        let updatedAt: Date
        let appearsInDashboard: Bool

        var id: Int64 { contentId }
        var isProcessing: Bool { phase == .queued || phase == .running }
    }

    static let shared = ContentProcessingStateStore()

    @Published private var entries: [Int64: Entry] = [:]

    func state(for contentId: Int64) -> Entry? {
        entries[contentId]
    }

    /// 数据看板使用的手动任务列表。活跃任务优先，其余按最近更新时间倒序。
    var dashboardEntries: [Entry] {
        entries.values.filter(\.appearsInDashboard).sorted {
            if $0.isProcessing != $1.isProcessing { return $0.isProcessing }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func enqueue(contentId: Int64, title: String, operation: String) {
        set(
            contentId: contentId, title: title, operation: operation,
            phase: .queued, message: "排队中…", appearsInDashboard: true)
    }

    func begin(contentId: Int64, title: String? = nil, operation: String? = nil,
               message: String) {
        set(
            contentId: contentId, title: title, operation: operation,
            phase: .running, message: message, appearsInDashboard: true)
    }

    func finish(contentId: Int64, message: String, succeeded: Bool? = nil) {
        let success = succeeded ?? (!message.contains("失败") && !message.contains("❌"))
        set(
            contentId: contentId, title: nil, operation: nil,
            phase: success ? .succeeded : .failed, message: message,
            appearsInDashboard: nil)
    }

    func notice(contentId: Int64, message: String) {
        // 未取得内容锁时没有创建新任务，仅更新当前文章的即时提示。
        let current = entries[contentId]
        set(
            contentId: contentId, title: current?.title, operation: current?.operation,
            phase: current?.phase ?? .failed, message: message,
            appearsInDashboard: current?.appearsInDashboard ?? false)
    }

    func clear(contentId: Int64) {
        entries.removeValue(forKey: contentId)
    }

    private func set(contentId: Int64, title: String?, operation: String?,
                     phase: Entry.Phase, message: String, appearsInDashboard: Bool?) {
        let current = entries[contentId]
        entries[contentId] = Entry(
            contentId: contentId,
            title: title ?? current?.title ?? "内容 #\(contentId)",
            operation: operation ?? current?.operation ?? "手动处理",
            phase: phase,
            message: message,
            updatedAt: Date(),
            appearsInDashboard: appearsInDashboard ?? current?.appearsInDashboard ?? false)
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
