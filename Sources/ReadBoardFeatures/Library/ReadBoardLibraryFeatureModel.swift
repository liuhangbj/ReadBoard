import Foundation
import Observation
import ReadBoardContract
import ReadBoardUI

public struct ReadBoardLibraryFeatureIdentity: Hashable, Sendable {
    public let location: ReadBoardLibraryLocation
    public let query: ReadBoardLibraryQueryIdentity

    public init(location: ReadBoardLibraryLocation, query: ReadBoardLibraryQueryIdentity) {
        self.location = location
        self.query = query
    }
}

/// 资料库完整页面的唯一状态模型。Core 与 Go 只注入不同 Gateway，不再分别实现加载和写回逻辑。
@MainActor
@Observable
public final class ReadBoardLibraryFeatureModel {
    private static let pageSize = 300
    public private(set) var location: ReadBoardLibraryLocation
    public var queryState: ReadBoardLibraryQueryState
    public private(set) var navigationSnapshot: LibrarySnapshot?
    public private(set) var items: [ContentSummary] = []
    public private(set) var selectedItem: ContentSummary?
    public private(set) var selectedDetail: ContentDetail?
    public private(set) var selection = ReadBoardLibrarySelectionState()
    public private(set) var pagination = ReadBoardLibraryPaginationState()
    public private(set) var detailIsLoading = false
    public private(set) var detailErrorMessage: String?
    public private(set) var operationErrorMessage: String?
    public private(set) var operationStatusMessage: String?

    private let environment: ReadBoardFeatureEnvironment
    private var loadedIdentity: ReadBoardLibraryFeatureIdentity?
    private var detailRequestID = UUID()
    private var stateMutationGeneration: [Int64: Int] = [:]

    public init(
        environment: ReadBoardFeatureEnvironment,
        location: ReadBoardLibraryLocation = .collection(.all)
    ) {
        self.environment = environment
        self.location = location
        self.queryState = ReadBoardLibraryQueryState(collection: location.baseCollection)
    }

    public var identity: ReadBoardLibraryFeatureIdentity {
        ReadBoardLibraryFeatureIdentity(location: location, query: queryState.identity)
    }

    public var permissions: ReadBoardFeaturePermissions { environment.permissions }

    public func setLocation(_ value: ReadBoardLibraryLocation) {
        guard value != location else { return }
        location = value
        queryState = ReadBoardLibraryQueryState(collection: value.baseCollection)
        pagination.reset()
        loadedIdentity = nil
    }

    public func clearOperationError() {
        operationErrorMessage = nil
    }

    public func clearOperationStatus() {
        operationStatusMessage = nil
    }

    /// 详情插槽完成数据库写回后，用服务端返回的权威状态归并列表。
    public func acceptAuthoritativeState(
        contentID: Int64,
        isRead: Bool,
        isStarred: Bool
    ) {
        applyState(contentID: contentID, isRead: isRead, isStarred: isStarred)
    }

    public func refreshNavigation() async {
        do {
            navigationSnapshot = try await environment.library.snapshot()
        } catch is CancellationError {
            return
        } catch {
            operationErrorMessage = error.localizedDescription
        }
    }

    public func searchAndReload() async {
        let requestedIdentity = identity
        if !requestedIdentity.query.search.isEmpty {
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard !Task.isCancelled, requestedIdentity == identity else { return }
        await reload(for: requestedIdentity)
    }

    public func reload() async {
        await reload(for: identity)
    }

    public func loadMore() async {
        let requestedIdentity = identity
        guard let request = pagination.beginLoadingMore() else { return }
        do {
            let base = queryState.contentQuery(
                cursor: request.cursor,
                pageSize: Self.pageSize)
            let page = try await environment.library.page(location.applying(to: base))
            guard !Task.isCancelled, requestedIdentity == identity else {
                pagination.cancelLoadingMore(request.token)
                return
            }
            items = ReadBoardLibraryPaginationState.appendingUnique(page.items, to: items)
            pagination.finishLoadingMore(request.token, nextCursor: page.nextCursor)
        } catch is CancellationError {
            pagination.cancelLoadingMore(request.token)
        } catch {
            guard requestedIdentity == identity else { return }
            pagination.failLoadingMore(request.token, message: error.localizedDescription)
        }
    }

    public func open(
        _ item: ContentSummary,
        automaticallyMarksRead: Bool = true,
        loadsDetail: Bool = true
    ) async {
        selection.select(item.id)
        selectedItem = item
        selectedDetail = nil
        detailErrorMessage = nil
        if loadsDetail {
            async let detail: Void = loadDetail(contentID: item.id)
            if automaticallyMarksRead, !item.isRead,
               permissions.allows(.updateReadingState, capability: .library) {
                await setRead(true, contentID: item.id)
            }
            await detail
            return
        }
        if automaticallyMarksRead, !item.isRead,
           permissions.allows(.updateReadingState, capability: .library) {
            await setRead(true, contentID: item.id)
        }
    }

    public func clearSelection() {
        selection.clear()
        selectedItem = nil
        selectedDetail = nil
        detailErrorMessage = nil
        detailRequestID = UUID()
    }

    public func setRead(_ value: Bool, contentID: Int64? = nil) async {
        guard permissions.allows(.updateReadingState, capability: .library),
              let contentID = contentID ?? selection.selectedID else { return }
        let generation = nextMutationGeneration(for: contentID)
        let previous = state(for: contentID)
        applyState(contentID: contentID, isRead: value, isStarred: previous.isStarred)
        do {
            let state = try await environment.library.setRead(contentID: contentID, isRead: value)
            guard mutationIsCurrent(generation, for: contentID) else { return }
            applyState(contentID: contentID, isRead: state.isRead, isStarred: state.isStarred)
            await refreshNavigationAfterMutation()
        } catch {
            guard mutationIsCurrent(generation, for: contentID) else { return }
            applyState(
                contentID: contentID,
                isRead: previous.isRead,
                isStarred: previous.isStarred)
            operationErrorMessage = error.localizedDescription
        }
    }

    public func setStarred(_ value: Bool, contentID: Int64? = nil) async {
        guard permissions.allows(.updateReadingState, capability: .library),
              let contentID = contentID ?? selection.selectedID else { return }
        let generation = nextMutationGeneration(for: contentID)
        let previous = state(for: contentID)
        applyState(contentID: contentID, isRead: previous.isRead, isStarred: value)
        do {
            let state = try await environment.library.setStarred(
                contentID: contentID, isStarred: value)
            guard mutationIsCurrent(generation, for: contentID) else { return }
            applyState(contentID: contentID, isRead: state.isRead, isStarred: state.isStarred)
            await refreshNavigationAfterMutation()
        } catch {
            guard mutationIsCurrent(generation, for: contentID) else { return }
            applyState(
                contentID: contentID,
                isRead: previous.isRead,
                isStarred: previous.isStarred)
            operationErrorMessage = error.localizedDescription
        }
    }

    public func markCurrentLocationRead() async {
        guard permissions.allows(.updateReadingState, capability: .library) else { return }
        do {
            let base = queryState.contentQuery(pageSize: 1)
            let summary = try await environment.library.markRead(
                filter: location.applying(to: base).filter)
            operationStatusMessage = "已标记 \(summary.affectedCount) 条为已读"
            await reload()
            await refreshNavigationAfterMutation()
        } catch {
            operationErrorMessage = error.localizedDescription
        }
    }

    public func submitProcessing(
        _ operation: ProcessingOperation,
        contentID: Int64
    ) async {
        guard permissions.allows(.runProcessing, capability: .processing) else { return }
        do {
            var snapshot = try await environment.processing.submit(
                ProcessingCommand(contentID: contentID, operation: operation))
            operationStatusMessage = snapshot.message
            while !snapshot.state.isTerminal, !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(800))
                snapshot = try await environment.processing.status(requestID: snapshot.requestID)
                operationStatusMessage = snapshot.message
            }
            if snapshot.contentChanged {
                await reload()
                if selection.selectedID == contentID,
                   let selectedItem {
                    await open(
                        selectedItem,
                        automaticallyMarksRead: false,
                        loadsDetail: true)
                }
            }
            if snapshot.state == .failed { operationErrorMessage = snapshot.message }
        } catch is CancellationError {
            return
        } catch {
            operationErrorMessage = error.localizedDescription
        }
    }

    public func forceExport(contentID: Int64) async {
        guard permissions.allows(.manageExports, capability: .export) else { return }
        do {
            let result = try await environment.export.forceExport(contentID: contentID)
            operationStatusMessage = result.message
            await reload()
        } catch {
            operationErrorMessage = error.localizedDescription
        }
    }

    public func selectAdjacent(
        offset: Int,
        automaticallyMarksRead: Bool = true,
        loadsDetail: Bool = true
    ) async {
        guard let targetID = selection.adjacentID(
            in: items.map(\.id), offset: offset),
            let item = items.first(where: { $0.id == targetID }) else { return }
        await open(
            item,
            automaticallyMarksRead: automaticallyMarksRead,
            loadsDetail: loadsDetail)
    }

    public func canSelectAdjacent(offset: Int) -> Bool {
        selection.adjacentID(in: items.map(\.id), offset: offset) != nil
    }

    private func reload(for requestedIdentity: ReadBoardLibraryFeatureIdentity) async {
        let isRecoveringFromLoadFailure = pagination.errorMessage != nil
        if loadedIdentity != requestedIdentity {
            items = []
            pagination.reset()
        }
        let requestToken = pagination.beginReload()
        do {
            let base = queryState.contentQuery(pageSize: Self.pageSize)
            let page = try await environment.library.page(location.applying(to: base))
            guard !Task.isCancelled, requestedIdentity == identity else {
                pagination.cancelReload(requestToken)
                return
            }
            items = page.items
            pagination.finishReload(requestToken, nextCursor: page.nextCursor)
            loadedIdentity = requestedIdentity
            // The navigation pane owns a separate lightweight snapshot.  If the
            // service was unavailable when both panes first appeared, a successful
            // list retry is the strongest signal that the sidebar should retry too.
            if isRecoveringFromLoadFailure {
                NotificationCenter.default.post(
                    name: .readBoardLibrarySnapshotChanged,
                    object: nil)
            }
        } catch is CancellationError {
            pagination.cancelReload(requestToken)
        } catch {
            guard requestedIdentity == identity else { return }
            pagination.failReload(requestToken, message: error.localizedDescription)
        }
    }

    private func loadDetail(contentID: Int64) async {
        let requestID = UUID()
        detailRequestID = requestID
        detailIsLoading = true
        do {
            let detail = try await environment.contentDetail.detail(contentID: contentID)
            guard !Task.isCancelled, detailRequestID == requestID,
                  selection.selectedID == contentID else { return }
            selectedDetail = detail
            detailIsLoading = false
        } catch is CancellationError {
            if detailRequestID == requestID { detailIsLoading = false }
        } catch {
            guard detailRequestID == requestID, selection.selectedID == contentID else { return }
            detailIsLoading = false
            detailErrorMessage = error.localizedDescription
        }
    }

    private func refreshNavigationAfterMutation() async {
        await refreshNavigation()
        NotificationCenter.default.post(name: .readBoardLibrarySnapshotChanged, object: nil)
    }

    private func state(for contentID: Int64) -> (isRead: Bool, isStarred: Bool) {
        if let selectedItem, selectedItem.id == contentID {
            return (selectedItem.isRead, selectedItem.isStarred)
        }
        if let item = items.first(where: { $0.id == contentID }) {
            return (item.isRead, item.isStarred)
        }
        return (false, false)
    }

    private func applyState(contentID: Int64, isRead: Bool, isStarred: Bool) {
        if let selectedItem, selectedItem.id == contentID {
            self.selectedItem = selectedItem.replacingState(
                isRead: isRead, isStarred: isStarred)
        }
        if (queryState.readFilter == .unread && isRead)
            || (queryState.readFilter == .starred && !isStarred) {
            items.removeAll { $0.id == contentID }
            return
        }
        guard let index = items.firstIndex(where: { $0.id == contentID }) else { return }
        items[index] = items[index].replacingState(isRead: isRead, isStarred: isStarred)
    }

    private func nextMutationGeneration(for contentID: Int64) -> Int {
        let value = (stateMutationGeneration[contentID] ?? 0) + 1
        stateMutationGeneration[contentID] = value
        return value
    }

    private func mutationIsCurrent(_ generation: Int, for contentID: Int64) -> Bool {
        stateMutationGeneration[contentID] == generation
    }
}
