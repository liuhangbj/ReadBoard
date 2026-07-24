import Foundation
import SwiftUI

@MainActor
public final class ContentViewModel: ObservableObject {
    @Published var sidebarTree: [SidebarNode] = []   // 左栏树：文件夹→源
    @Published var items: [ContentItem] = []
    /// 左栏选中的过滤键：nil=全部，"source_id=N"=单源，"folder_id=N"=文件夹
    @Published var selectedFilter: String? = nil
    @Published var selectedItem: ContentItem? = nil
    @Published var minScore: Int = 0               // 评分筛选 0=不限
    @Published var includeUnscored: Bool = false   // 评分筛选时是否含未评分
    /// 阅读状态单选：all=全部 / unread=未读 / starred=星标（三选一）
    @Published var readFilter: ReadFilter = .all
    @Published var showArchived: Bool = false      // 看归档（默认看活跃）
    /// 处理状态筛选（多选）：score/summary/translate/transcribe。空 = 不限。
    /// 多选为「或」关系（满足任一即纳入），符合"我想看已打分或已翻译的"直觉。
    @Published var processedFilters: Set<String> = []
    @Published var keyword: String = ""            // 搜索关键词（标题/正文）

    enum ReadFilter: String, CaseIterable {
        case all, unread, starred
        var display: String {
            switch self {
            case .all: return "全部"
            case .unread: return "未读"
            case .starred: return "星标"
            }
        }
    }
    @Published var selectedTag: Tag? = nil         // 标签筛选 nil=不限
    @Published var tags: [Tag] = []                // 全部标签（筛选下拉）
    @Published var totalCount: Int = 0
    @Published var showTranslated: Bool = false    // 阅读区显示原文/翻译
    @Published var searchFocused: Bool = false     // 搜索框焦点（快捷键避让）

    /// 从 selectedFilter 解析 sourceId / folderId
    private var selectedSourceId: Int64? {
        guard let f = selectedFilter, f.hasPrefix("source_id=") else { return nil }
        return Int64(f.replacingOccurrences(of: "source_id=", with: ""))
    }
    private var selectedFolderId: Int64? {
        guard let f = selectedFilter, f.hasPrefix("folder_id=") else { return nil }
        return Int64(f.replacingOccurrences(of: "folder_id=", with: ""))
    }

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

    /// NotificationCenter observer token——block-based addObserver 的返回值须持有并在 deinit 移除，
    /// 否则 ViewModel 释放后 observer 注册泄漏（weak self 防崩溃但注册表越积越多）。
    /// nonisolated(unsafe)：NSObjectProtocol 非 Sendable，@MainActor 类的 deinit 是非隔离的，
    /// 直接访问存储属性会被 Swift 6 并发检查拦。observer token 本身线程安全（removeObserver 可任意线程调）。
    private nonisolated(unsafe) var updateObserver: NSObjectProtocol?

    init() {
        // 评分/翻译完成后刷新列表与当前选中项
        updateObserver = NotificationCenter.default.addObserver(
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

    deinit {
        if let obs = updateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func loadAll() {
        totalCount = db.totalCount()
        sidebarTree = db.fetchSidebarTree()
        tags = TagService.shared.allTags()
        reload()
    }

    /// 每页条数（滚动到底自动加载下一页）
    static let pageSize = 300
    /// 是否可能还有更多（上次取回的数量 == pageSize）
    @Published var hasMore: Bool = false

    func reload() {
        let minS: Int? = minScore > 0 ? minScore : nil
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        let page = db.fetchContents(sourceId: selectedSourceId, folderId: selectedFolderId,
                                    minScore: minS,
                                    includeUnscored: includeUnscored,
                                    unreadOnly: readFilter == .unread,
                                    keyword: kw.isEmpty ? nil : kw,
                                    starredOnly: readFilter == .starred,
                                    archived: showArchived,
                                    tagId: selectedTag?.id,
                                    processedFilters: processedFilters,
                                    limit: Self.pageSize, offset: 0)
        items = page
        hasMore = page.count >= Self.pageSize
        if let sel = selectedItem, !items.contains(sel) {
            selectedItem = nil
        }
    }

    /// 加载下一页（滚动到底触发）。追加而非替换。
    func loadMore() {
        guard hasMore else { return }
        let minS: Int? = minScore > 0 ? minScore : nil
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        let page = db.fetchContents(sourceId: selectedSourceId, folderId: selectedFolderId,
                                    minScore: minS,
                                    includeUnscored: includeUnscored,
                                    unreadOnly: readFilter == .unread,
                                    keyword: kw.isEmpty ? nil : kw,
                                    starredOnly: readFilter == .starred,
                                    archived: showArchived,
                                    tagId: selectedTag?.id,
                                    processedFilters: processedFilters,
                                    limit: Self.pageSize,
                                    offset: items.count)
        hasMore = page.count >= Self.pageSize
        // 去重追加（极端情况数据在两次查询间被插入，offset 可能重叠几条）
        let existing = Set(items.map { $0.id })
        items.append(contentsOf: page.filter { !existing.contains($0.id) })
    }

    /// 左栏选中：nil=全部，"source_id=N" / "folder_id=N"
    func selectFilter(_ filter: String?) {
        selectedFilter = filter
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

    /// 切换归档（归档后从活跃列表消失；取消归档回到活跃列表）
    func toggleArchive(_ item: ContentItem) {
        let wasArchived = item.archived
        db.toggleArchive(contentId: item.id)
        reload()
        // 取消归档且当前不在看归档视图时给提示——否则文章"消失"用户不知去哪了
        if wasArchived && !showArchived {
            showToast("已取消归档，回到活跃列表")
        }
    }

    // MARK: 轻提示（3s 自动消失）
    @Published var toastMessage: String? = nil
    private var toastTask: Task<Void, Never>?
    private func showToast(_ msg: String) {
        toastMessage = msg
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    /// 全部标已读（按当前筛选范围）。返回影响条数。
    @discardableResult
    func markAllRead() -> Int {
        let minS: Int? = minScore > 0 ? minScore : nil
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        let n = db.markAllRead(sourceId: selectedSourceId, folderId: selectedFolderId,
                               minScore: minS, keyword: kw.isEmpty ? nil : kw)
        reload()
        return n
    }

    // MARK: 快捷键导航（搜索框聚焦时禁用，避免空格/j/k 被列表抢走）

    /// 选中下一篇
    func selectNext() { guard !searchFocused else { return }; moveSelection(by: 1) }
    /// 选中上一篇
    func selectPrev() { guard !searchFocused else { return }; moveSelection(by: -1) }

    /// 快捷键触发已读切换（空格）——搜索框聚焦时忽略
    func shortcutToggleRead() {
        guard !searchFocused, let it = selectedItem else { return }
        toggleRead(it)
    }

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
