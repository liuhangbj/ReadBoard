import Foundation
import ReadBoardContract

public struct ReadBoardLibraryQueryIdentity: Hashable, Sendable {
    public let search: String
    public let readFilter: String
    public let categoryFilter: String
    public let sort: String
    public let minimumScore: Int
    public let maximumScore: Int
    public let includeUnscored: Bool
    public let processing: [ProcessingCriterion]

    public init(
        search: String,
        readFilter: String,
        categoryFilter: String,
        sort: String,
        minimumScore: Int = 0,
        maximumScore: Int = 100,
        includeUnscored: Bool = false,
        processing: [ProcessingCriterion] = []
    ) {
        self.search = search
        self.readFilter = readFilter
        self.categoryFilter = categoryFilter
        self.sort = sort
        self.minimumScore = minimumScore
        self.maximumScore = maximumScore
        self.includeUnscored = includeUnscored
        self.processing = processing
    }
}

public struct ReadBoardLibraryEmptyPresentation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let systemImage: String

    public init(title: String, message: String, systemImage: String) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }
}

public enum ReadBoardLibrarySelectionRetention: Equatable, Sendable {
    /// 刷新或筛选后即使当前页不再包含该文章，也继续保留阅读区。
    case preserveReading
    /// 当前页不再包含该文章时清除选择。
    case requireVisibleItem
}

/// 资料库选择只保存稳定的 Contract ID，不持有本地数据库对象或远程 DTO。
public struct ReadBoardLibrarySelectionState: Equatable, Sendable {
    public private(set) var selectedID: Int64?

    public init(selectedID: Int64? = nil) {
        self.selectedID = selectedID
    }

    public var hasSelection: Bool { selectedID != nil }

    public func isSelected(_ id: Int64) -> Bool {
        selectedID == id
    }

    public mutating func select(_ id: Int64) {
        selectedID = id
    }

    public mutating func clear() {
        selectedID = nil
    }

    @discardableResult
    public mutating func removeIfSelected(_ id: Int64) -> Bool {
        guard selectedID == id else { return false }
        selectedID = nil
        return true
    }

    @discardableResult
    public mutating func reconcile(
        availableIDs: [Int64],
        retention: ReadBoardLibrarySelectionRetention
    ) -> Bool {
        guard retention == .requireVisibleItem, let selectedID else { return false }
        guard !availableIDs.contains(selectedID) else { return false }
        self.selectedID = nil
        return true
    }

    public func adjacentID(in orderedIDs: [Int64], offset: Int) -> Int64? {
        guard !orderedIDs.isEmpty, offset != 0 else { return selectedID }
        guard let selectedID,
              let currentIndex = orderedIDs.firstIndex(of: selectedID) else {
            return offset > 0 ? orderedIDs.first : orderedIDs.last
        }
        let target = currentIndex + offset
        guard orderedIDs.indices.contains(target) else { return nil }
        return orderedIDs[target]
    }
}

/// Core 与 Go 共用的完整资料库查询意图。任何会改变列表结果的条件都必须放在这里，
/// 避免产品壳各自追加筛选并重新形成两套行为。
public struct ReadBoardLibraryQueryState: Equatable, Sendable {
    public let collection: ReadBoardLibraryCollection
    public var searchText: String
    public var readFilter: ReadBoardLibraryReadFilter
    public var categoryFilter: ReadBoardLibraryCategoryFilter
    public var sortOption: ReadBoardLibrarySortOption
    public var minimumScore: Int
    public var maximumScore: Int
    public var includeUnscored: Bool
    public var processing: [ProcessingKind: ProcessingMatch]

    public init(
        collection: ReadBoardLibraryCollection = .all,
        searchText: String = "",
        readFilter: ReadBoardLibraryReadFilter? = nil,
        categoryFilter: ReadBoardLibraryCategoryFilter? = nil,
        sortOption: ReadBoardLibrarySortOption = .newest,
        minimumScore: Int = 0,
        maximumScore: Int = 100,
        includeUnscored: Bool = false,
        processing: [ProcessingKind: ProcessingMatch] = [:]
    ) {
        self.collection = collection
        self.searchText = searchText
        self.readFilter = readFilter ?? collection.initialReadFilter
        self.categoryFilter = categoryFilter ?? collection.initialCategoryFilter
        self.sortOption = sortOption
        self.minimumScore = minimumScore
        self.maximumScore = maximumScore
        self.includeUnscored = includeUnscored
        self.processing = processing
    }

    public var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var identity: ReadBoardLibraryQueryIdentity {
        let bounds = normalizedScoreBounds
        return ReadBoardLibraryQueryIdentity(
            search: trimmedSearch,
            readFilter: readFilter.rawValue,
            categoryFilter: categoryFilter.rawValue,
            sort: sortOption.rawValue,
            minimumScore: bounds.minimum,
            maximumScore: bounds.maximum,
            includeUnscored: includeUnscored,
            processing: processingCriteria)
    }

    public var hasActiveFilter: Bool {
        !trimmedSearch.isEmpty
            || readFilter != collection.initialReadFilter
            || categoryFilter != collection.initialCategoryFilter
            || sortOption != .newest
            || normalizedScoreBounds.minimum > 0
            || normalizedScoreBounds.maximum < 100
            || !processing.isEmpty
    }

    public var emptyPresentation: ReadBoardLibraryEmptyPresentation {
        if hasActiveFilter {
            return .init(
                title: "没有匹配的内容",
                message: "试试更换关键词或减少筛选条件。",
                systemImage: "magnifyingglass")
        }
        return .init(
            title: "暂无内容",
            message: "ReadBoard 抓取的新内容会显示在这里。",
            systemImage: "tray")
    }

    public mutating func reset() {
        searchText = ""
        readFilter = collection.initialReadFilter
        categoryFilter = collection.initialCategoryFilter
        sortOption = .newest
        minimumScore = 0
        maximumScore = 100
        includeUnscored = false
        processing = [:]
    }

    public func contentQuery(cursor: String? = nil, pageSize: Int = 50) -> ContentQuery {
        let bounds = normalizedScoreBounds
        return ContentQuery(
            filter: ContentFilter(
                category: categoryFilter.category,
                minimumScore: bounds.minimum == 0 ? nil : bounds.minimum,
                maximumScore: bounds.maximum == 100 ? nil : bounds.maximum,
                includeUnscored: includeUnscored,
                readState: readFilter.readState,
                keyword: trimmedSearch.isEmpty ? nil : trimmedSearch,
                processing: processingCriteria),
            sort: sortOption.sort,
            pageSize: pageSize,
            cursor: cursor)
    }

    public var normalizedScoreBounds: (minimum: Int, maximum: Int) {
        let lower = min(100, max(0, minimumScore))
        let upper = min(100, max(0, maximumScore))
        return (lower, upper)
    }

    public var processingCriteria: [ProcessingCriterion] {
        processing.map { ProcessingCriterion(kind: $0.key, match: $0.value) }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
    }
}

public struct ReadBoardLibraryPageRequest: Hashable, Sendable {
    public let token: UUID
    public let cursor: String

    fileprivate init(token: UUID, cursor: String) {
        self.token = token
        self.cursor = cursor
    }
}

/// 统一首次加载、刷新和游标分页的生命周期。
/// 每次请求都带 token，已取消或过期的返回不会结束较新的请求状态。
public struct ReadBoardLibraryPaginationState: Equatable, Sendable {
    public private(set) var nextCursor: String?
    public private(set) var isInitialLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var errorMessage: String?

    private var reloadToken: UUID?
    private var loadMoreToken: UUID?

    public init(nextCursor: String? = nil) {
        self.nextCursor = nextCursor
    }

    public var hasMore: Bool { nextCursor != nil }

    @discardableResult
    public mutating func beginReload() -> UUID {
        let token = UUID()
        reloadToken = token
        loadMoreToken = nil
        isInitialLoading = true
        isLoadingMore = false
        errorMessage = nil
        return token
    }

    public mutating func finishReload(_ token: UUID, nextCursor: String?) {
        guard reloadToken == token else { return }
        reloadToken = nil
        isInitialLoading = false
        self.nextCursor = nextCursor
    }

    public mutating func failReload(_ token: UUID, message: String) {
        guard reloadToken == token else { return }
        reloadToken = nil
        isInitialLoading = false
        errorMessage = message
    }

    public mutating func cancelReload(_ token: UUID) {
        guard reloadToken == token else { return }
        reloadToken = nil
        isInitialLoading = false
    }

    public mutating func beginLoadingMore() -> ReadBoardLibraryPageRequest? {
        guard !isInitialLoading, !isLoadingMore, let nextCursor else { return nil }
        let token = UUID()
        loadMoreToken = token
        isLoadingMore = true
        errorMessage = nil
        return ReadBoardLibraryPageRequest(token: token, cursor: nextCursor)
    }

    public mutating func finishLoadingMore(_ token: UUID, nextCursor: String?) {
        guard loadMoreToken == token else { return }
        loadMoreToken = nil
        isLoadingMore = false
        self.nextCursor = nextCursor
    }

    public mutating func failLoadingMore(_ token: UUID, message: String) {
        guard loadMoreToken == token else { return }
        loadMoreToken = nil
        isLoadingMore = false
        errorMessage = message
    }

    public mutating func cancelLoadingMore(_ token: UUID) {
        guard loadMoreToken == token else { return }
        loadMoreToken = nil
        isLoadingMore = false
    }

    public mutating func reset() {
        nextCursor = nil
        reloadToken = nil
        loadMoreToken = nil
        isInitialLoading = false
        isLoadingMore = false
        errorMessage = nil
    }

    public static func appendingUnique<Item: Identifiable>(
        _ incoming: [Item], to existing: [Item]
    ) -> [Item] where Item.ID: Hashable {
        let existingIDs = Set(existing.map(\.id))
        return existing + incoming.filter { !existingIDs.contains($0.id) }
    }
}
