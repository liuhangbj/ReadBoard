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
    @Published var starredOnly: Bool = false       // 只看星标
    @Published var showArchived: Bool = false      // 看归档（默认看活跃）
    @Published var keyword: String = ""            // 搜索关键词（标题/正文）
    @Published var totalCount: Int = 0
    @Published var showTranslated: Bool = false    // 阅读区显示原文/翻译

    private let db = Database.shared
    /// 搜索防抖：连续输入时取消上一次未执行的 reload
    private var searchTask: Task<Void, Never>?

    /// 搜索框输入时调用——300ms 防抖，避免每敲一字就全库查一次
    func reloadDebounced() {
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

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
                                 unreadOnly: unreadOnly, keyword: kw.isEmpty ? nil : kw,
                                 starredOnly: starredOnly, archived: showArchived, limit: 300)
        if let sel = selectedItem, !items.contains(sel) {
            selectedItem = nil
        }
    }

    func selectSource(_ source: String?) {
        selectedSource = source
        reload()
    }

    /// 打开文章：选中并标已读，异步加载正文（列表是轻列，正文点开才查）
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
        loadBodyIfNeeded(for: item.id)
    }

    /// 正文/译文/媒体地址按需加载：列表查询不取这些大字段，点开才查并填回 selectedItem
    private func loadBodyIfNeeded(for id: Int64) {
        // 已有正文则不重复查
        if selectedItem?.id == id, selectedItem?.contentMd != nil || selectedItem?.audioUrl != nil { return }
        let currentId = id
        Task.detached(priority: .userInitiated) { [db] in
            guard let body = db.fetchContentBody(id: currentId) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.selectedItem?.id == currentId else { return }
                self.selectedItem = self.selectedItem?.withBody(
                    contentMd: body.contentMd, llmTranslatedMd: body.llmTranslatedMd, audioUrl: body.audioUrl)
            }
        }
    }

    /// 切换已读/未读
    func toggleRead(_ item: ContentItem) {
        if item.isRead { db.markUnread(contentId: item.id) }
        else { db.markRead(contentId: item.id) }
        reload()
    }

    /// 切换星标
    func toggleStar(_ item: ContentItem) {
        db.toggleStar(contentId: item.id)
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = items[idx].togglingStar()
        }
        if selectedItem?.id == item.id { selectedItem = items.first { $0.id == item.id } }
    }

    /// 切换归档（归档后从活跃列表消失）
    func toggleArchive(_ item: ContentItem) {
        db.toggleArchive(contentId: item.id)
        reload()
    }

    /// 全部标已读（按当前筛选范围）。返回影响条数。
    @discardableResult
    func markAllRead() -> Int {
        let minS: Int? = minScore > 0 ? minScore : nil
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        let n = db.markAllRead(source: selectedSource, minScore: minS, keyword: kw.isEmpty ? nil : kw)
        reload()
        return n
    }

    // MARK: 快捷键导航

    /// 选中下一篇
    func selectNext() { moveSelection(by: 1) }
    /// 选中上一篇
    func selectPrev() { moveSelection(by: -1) }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        if let cur = selectedItem, let idx = items.firstIndex(where: { $0.id == cur.id }) {
            let next = max(0, min(items.count - 1, idx + delta))
            open(items[next])
        } else {
            open(delta > 0 ? items[0] : items[items.count - 1])
        }
    }
}
