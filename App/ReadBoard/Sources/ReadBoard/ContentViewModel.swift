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
    /// 阅读状态单选：all=全部 / unread=未读 / starred=星标
    @Published var readFilter: ReadFilter = .all
    /// 处理状态三态筛选：score/summary/translate/transcribe。
    /// 每键三态：.none 不筛选 / .yes 已处理（实色高亮）/ .no 未处理（淡粉高亮）。
    /// 多选为「或」关系（满足任一条件即纳入），跨键可混合 yes/no。
    @Published var processedStates: [String: ProcessedState] = [:]

    /// 处理状态三态：none=不筛选 / yes=已处理（实色）/ no=未处理（淡粉）
    enum ProcessedState: Int {
        case none = 0, yes = 1, no = 2
        /// 点击循环：none → yes → no → none
        var next: ProcessedState {
            switch self { case .none: return .yes; case .yes: return .no; case .no: return .none }
        }
    }
    @Published var keyword: String = ""            // 搜索关键词（标题/正文）
    /// 文章列表排序：newest（最新优先，默认）/ oldest（最早优先）/ score（评分优先）
    @Published var sortOrder: SortOrder = .newest

    enum SortOrder: String, CaseIterable, Identifiable {
        case newest, oldest, score
        var id: String { rawValue }
        var display: String {
            switch self {
            case .newest: return "最新"
            case .oldest: return "最早"
            case .score: return "评分"
            }
        }
    }

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
    @Published var totalCount: Int = 0
    @Published var totalUnread: Int = 0   // 全部文章未读数（左栏「全部文章」行显示 未读/总数）
    @Published var totalExported: Int = 0  // 已导出文章数
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
    /// 已读连点时合并左栏计数刷新；只更新统计，不触碰 items，避免表格重建。
    private var sidebarRefreshTask: Task<Void, Never>?

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
        // 评分/翻译完成后刷新列表。
        // ⚠️ 根因修复（11:47 系统日志符号化堆栈实锤）：
        // 原实现 `Task { @MainActor in self.reload() }` —— Task @MainActor 会被 SwiftUI
        // 在当前视图更新周期内排干执行 → reload() 写 @Published items 正中
        // "Publishing changes from within view updates is not allowed"
        // （堆栈：items.setter ← reload() ← 本闭包）→ 渲染提交被判 undefined behavior 丢弃，
        // 全 app 出现「点了不上屏、再点任意处才上屏」的家族病（切标签/AI按钮/摘要卡/译文标题/图片）。
        // GCD DispatchQueue.main.async 是独立 runloop 回调，不会被卷进视图更新周期——
        // 这是逃离"更新中发布"的标准通道。
        //
        // 同块内恢复刷新 selectedItem 实例（当年禁用是因 Task 在布局期执行→分支切换→UAF）：
        // GCD 延迟块在布局外执行，且 ContentItem 相等只比 id（List 选中态保持）——
        // 两个崩溃前提都不在了。恢复后：翻译/摘要/评分完成 → 译文标题/摘要卡/评分标自动上屏，
        // 不再靠「切别的文章再切回来」。注意列表是轻列：llmTranslatedMd/contentMd 仍靠
        // ReadingView 的 @State/DB 兜底（translatedText），不依赖本实例。
        updateObserver = NotificationCenter.default.addObserver(
            forName: .contentUpdated, object: nil, queue: .main
        ) { [weak self] _ in
            // GCD 异步（非 Task @MainActor）——独立 runloop 回调，不会被 SwiftUI 卷进
            // 当前视图更新周期 → 不再触发 "Publishing changes from within view updates"。
            // ⚠️ 防抖合并（05:08 渲染风暴实锤）：后台管线每完成一件就 post 一次，
            // 逐次 reload = 300 行 + 300 个 AsyncImage 全量重建 ×N 次/分钟 → 内存疯涨 + AG cycle。
            // 0.75s 合并：连发只跑最后一次 reload，风暴砍成一次。
            guard let self else { return }
            self.pendingReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.reload()
                // 仍然不替换 selectedItem——替换会诱发 AttributeGraph 无限重绘循环（12:10 hang 实锤）。
                // 正文/摘要/译文标题新鲜度由 ReadingView 的 @State 镜像 + DB 兜底链解决。
            }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
        }
    }

    /// 通知防抖用的可取消工作项（连发 contentUpdated 时只保留最后一个）
    private var pendingReload: DispatchWorkItem?

    deinit {
        if let obs = updateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func loadAll() {
        totalCount = db.totalCount()
        totalUnread = db.totalUnread()
        totalExported = db.totalExported()
        sidebarTree = db.fetchSidebarTree()
        reload()
    }

    /// 每页条数（滚动到底自动加载下一页）
    static let pageSize = 300
    /// 是否可能还有更多（上次取回的数量 == pageSize）
    @Published var hasMore: Bool = false

    /// reload 序号（最新者优先）：快速连续触发时旧查询结果直接丢弃
    private var reloadSeq = 0

    /// 重新加载（异步版，17:05 定案）：
    /// 原版在主线程同步跑 fetchContents(300行) + sidebarTree + 两组计数——
    /// 67k 行库上每次切文件夹/订阅源都按出风火轮（用户实测定位）。
    /// DB 查询放后台，@Published 回主线程写；reloadSeq 保证乱序归并以最新为准。
    func reload() {
        reloadSeq += 1
        let seq = reloadSeq
        let minS: Int? = minScore > 0 ? minScore : nil
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        let keywordArg = kw.isEmpty ? nil : kw
        let sourceId = selectedSourceId
        let folderId = selectedFolderId
        let unscored = includeUnscored
        let unreadOnly = readFilter == .unread
        let starredOnly = readFilter == .starred
        let exportedOnly = selectedFilter == "exported"
        let processed = processedStates.mapValues { $0.rawValue }
        let sort = sortOrder.rawValue
        let pageSize = Self.pageSize
        Task.detached(priority: .userInitiated) {
            let page = Database.shared.fetchContents(sourceId: sourceId, folderId: folderId,
                                        minScore: minS,
                                        includeUnscored: unscored,
                                        unreadOnly: unreadOnly,
                                        exportedOnly: exportedOnly,
                                        keyword: keywordArg,
                                        starredOnly: starredOnly,
                                        processedFilters: processed, sortOrder: sort,
                                        limit: pageSize, offset: 0)
            let tree = Database.shared.fetchSidebarTree()
            let total = Database.shared.totalCount()
            let unread = Database.shared.totalUnread()
            let exported = Database.shared.totalExported()
            await MainActor.run { [weak self] in
                guard let self, self.reloadSeq == seq else { return }
                self.items = page
                self.hasMore = page.count >= Self.pageSize
                // 修 P1-6：筛选变化（哪怕改排序）不再销毁正在读的文章——保留 selectedItem，
                // 用户继续读完当前篇，不因筛选/排序变化被关掉。
                self.sidebarTree = tree
                self.totalCount = total
                self.totalUnread = unread
                self.totalExported = exported
                // 全量重查后 DB 已权威——清空乐观已读标记（防与「标为未读」等操作打架）
                self.readMarks.removeAll()
            }
        }
    }

    /// 轻量刷新左栏订阅树和总未读数，不重查/替换文章列表。
    /// 在已读写入确认完成后调用，避免异步写后立即读到旧计数。
    private func refreshSidebarCounts() {
        sidebarRefreshTask?.cancel()
        sidebarRefreshTask = Task { @MainActor [weak self] in
            // 快速连续打开文章时合并多次计数查询。
            do { try await Task.sleep(nanoseconds: 80_000_000) }
            catch { return }
            let stats = await Task.detached(priority: .utility) {
                let tree = Database.shared.fetchSidebarTree()
                let unread = Database.shared.totalUnread()
                return (tree, unread)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.sidebarTree = stats.0
            self.totalUnread = stats.1
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
                                    exportedOnly: selectedFilter == "exported",
                                    keyword: kw.isEmpty ? nil : kw,
                                    starredOnly: readFilter == .starred,
                                    processedFilters: processedStates.mapValues { $0.rawValue },
                                    sortOrder: sortOrder.rawValue,
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
        Trace.i("open 文章 id=\(item.id) ctype=\(item.ctype) mem=\(Trace.mb())MB", category: "read")
        let wasUnread = !item.isRead
        // 选中项立即出详情；未读则给阅读区一个已读实例（工具条已读态即时正确）。
        // 这只是个新实例，不碰 items 数组——表格数据纹丝不动。
        selectedItem = wasUnread ? item.markingRead() : item
        if wasUnread {
            // 写库仍在后台串行队列；完成后只刷新左栏计数，不改写 items。
            db.markRead(contentId: item.id) { [weak self] ok in
                guard let self else { return }
                if ok {
                    self.refreshSidebarCounts()
                } else {
                    // 极少数写入失败时撤销详情区的乐观已读态。
                    if self.selectedItem?.id == item.id { self.selectedItem = item }
                    self.readMarks[item.id] = nil
                }
            }
            // ⚠️ 铁证：任何对 items（表格数据源）的改写——同步/0.3s 延迟——快速连点时
            // 都会落进渲染窗口 → reentrant → AG cycle → 闪退（watch5/7 对照实验）。
            // 已读标记走非结构性通道：readMarks 只影响行内颜色/圆点（表格结构纹丝不动），
            // 即便落在渲染窗口也只是"更新中发布"（丢一帧自愈），不会重入崩溃。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.readMarks[item.id] == nil else { return }
                self.readMarks[item.id] = true
            }
        }
        loadBodyIfNeeded(for: item.id)
    }

    /// 正文/译文/媒体地址按需加载：列表查询不取这些大字段，点开才查并填回 selectedItem
    private func loadBodyIfNeeded(for id: Int64) {
        // 已有正文则不重复查。媒体项(audioUrl 非空)也要查——需 content_html(原文标签)/excerptTranslated(译文标签)
        if selectedItem?.id == id, selectedItem?.contentMd != nil, selectedItem?.contentHtml != nil { return }
        let currentId = id
        Trace.d("loadBodyIfNeeded 起 fetchContentBody id=\(currentId)", category: "read")
        Task.detached(priority: .userInitiated) { [db] in
            let t0 = Date()
            guard let body = db.fetchContentBody(id: currentId) else {
                Trace.w("fetchContentBody 返回 nil id=\(currentId)", category: "read")
                return
            }
            let mdKb = (body.contentMd ?? "").count / 1024
            let htmlKb = (body.contentHtml ?? "").count / 1024
            let transKb = (body.llmTranslatedMd ?? "").count / 1024
            Trace.i("fetchContentBody 完成 id=\(currentId) content_md=\(mdKb)KB content_html=\(htmlKb)KB llm_translated_md=\(transKb)KB 用时=\(Int(t0.timeIntervalSinceNow * -1000))ms mem=\(Trace.mb())MB", category: "read")
            await MainActor.run { [weak self] in
                guard let self, self.selectedItem?.id == currentId else { return }
                // 不替换 selectedItem——ReadingView 的 @State loadContentMd 已同步加载
                // contentMd/llmTranslatedMd 等字段。替换 selectedItem 会触发
                // "Publishing changes from within view updates" → 无限重绘循环 →
                // AttributeGraph cycle → StackLayout.makeChildren use-after-free 崩溃。
            }
        }
    }

    /// 切换已读/未读
    func toggleRead(_ item: ContentItem) {
        let targetRead = !effectiveIsRead(item)
        // 只改轻量覆盖字典，文章列表结构保持不变。
        readMarks[item.id] = targetRead
        let completion: @MainActor @Sendable (Bool) -> Void = { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.readMarks[item.id] = nil
                return
            }
            // “未读”筛选下标为已读会移出列表，必须重查；其他视图只更新左栏计数。
            if self.readFilter == .unread {
                self.reload()
            } else {
                self.refreshSidebarCounts()
            }
        }
        if targetRead {
            db.markRead(contentId: item.id, completion: completion)
        } else {
            db.markUnread(contentId: item.id, completion: completion)
        }
    }

    /// 行内乐观状态优先于列表快照；供行样式和右键菜单共用。
    func effectiveIsRead(_ item: ContentItem) -> Bool {
        if let override = readMarks[item.id] { return override }
        if selectedItem?.id == item.id { return selectedItem?.isRead ?? item.isRead }
        return item.isRead
    }

    /// 切换星标
    func toggleStar(_ item: ContentItem) {
        let newStarred = db.toggleStar(contentId: item.id) { [weak self] ok, starred in
            guard let self else { return }
            if ok {
                if starred {
                    Task { await ExportService.shared.runPending(trigger: "starred", contentId: item.id) }
                }
            } else {
                self.reload()
            }
        }
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            if items[idx].starred != newStarred { items[idx] = items[idx].togglingStar() }
        }
        if selectedItem?.id == item.id { selectedItem = items.first { $0.id == item.id } }
    }

    // MARK: 轻提示（3s 自动消失）
    @Published var toastMessage: String? = nil
    /// 已读乐观覆盖（非结构性）：true=已读、false=未读，ArticleRow 据此即时更新。
    /// 不碰 items（表格数据源），重载后 DB 已权威即清空。详见 open() 注释（watch5/7 对照实验）。
    @Published var readMarks: [Int64: Bool] = [:]
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
                               minScore: minS, includeUnscored: includeUnscored,
                               keyword: kw.isEmpty ? nil : kw,
                               starredOnly: readFilter == .starred,
                               processedFilters: processedStates.mapValues { $0.rawValue })
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
