import Foundation
import SwiftUI

@MainActor
final class ContentViewModel: ObservableObject {
    @Published var sourceGroups: [SourceGroup] = []
    @Published var items: [ContentItem] = []
    @Published var selectedSource: String? = nil   // nil = 全部
    @Published var selectedItem: ContentItem? = nil
    @Published var minScore: Int = 0               // 评分筛选 0=不限
    @Published var unreadOnly: Bool = false        // 只看未读
    @Published var keyword: String = ""            // 搜索关键词（标题/正文）
    @Published var totalCount: Int = 0
    @Published var showTranslated: Bool = false    // 阅读区显示原文/翻译

    private let db = Database.shared

    init() {
        // 评分/翻译完成后刷新列表与当前选中项
        NotificationCenter.default.addObserver(
            forName: .contentUpdated, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let currentId = self.selectedItem?.id
                self.reload()
                if let cid = currentId {
                    self.selectedItem = self.items.first { $0.id == cid }
                }
            }
        }
    }

    func loadAll() {
        totalCount = db.totalCount()
        sourceGroups = db.fetchSourceGroups()
        reload()
    }

    func reload() {
        let minS: Int? = minScore > 0 ? minScore : nil
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        items = db.fetchContents(source: selectedSource, minScore: minS,
                                 unreadOnly: unreadOnly, keyword: kw.isEmpty ? nil : kw, limit: 300)
        if let sel = selectedItem, !items.contains(sel) {
            selectedItem = nil
        }
    }

    func selectSource(_ source: String?) {
        selectedSource = source
        reload()
    }

    /// 打开文章：选中并标已读
    func open(_ item: ContentItem) {
        selectedItem = item
        if !item.isRead {
            db.markRead(contentId: item.id)
            // 本地同步已读状态，避免等下次 reload
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = items[idx].markingRead()
            }
            selectedItem = items.first { $0.id == item.id }
        }
    }

    /// 切换已读/未读
    func toggleRead(_ item: ContentItem) {
        if item.isRead { db.markUnread(contentId: item.id) }
        else { db.markRead(contentId: item.id) }
        reload()
    }
}
