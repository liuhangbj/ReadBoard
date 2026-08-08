import Foundation
import Combine
import ReadBoardContract

extension Notification.Name {
    static let sourceCatalogUpdated = Notification.Name("sourceCatalogUpdated")
}

@MainActor
final class SourceCatalogStore: ObservableObject {
    @Published private(set) var snapshot = SourceCatalogSnapshot()
    @Published private(set) var isLoading = false
    private let gateway: any SourceCatalogGateway
    private var catalogObserver: AnyCancellable?

    init(gateway: any SourceCatalogGateway) {
        self.gateway = gateway
        catalogObserver = NotificationCenter.default.publisher(for: .sourceCatalogUpdated)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
    }

    var sources: [SourceCatalogItem] { snapshot.sources }
    var folders: [SourceFolderItem] { snapshot.folders }
    var isSyncing: Bool { snapshot.isSyncing || snapshot.isExternalSyncing }
    var lastSyncMessage: String { snapshot.lastSyncMessage }

    func sources(inFolder folderID: Int64) -> [SourceCatalogItem] {
        sources.filter { $0.folderID == folderID }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let loaded = try? await gateway.snapshot() { snapshot = loaded }
    }

    func monitor(intervalNanoseconds: UInt64 = 30_000_000_000) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
    }
}

@MainActor
final class RuntimeStatusStore: ObservableObject {
    @Published private(set) var snapshot = RuntimeStatusSnapshot()
    private let gateway: any RuntimeStatusGateway

    init(gateway: any RuntimeStatusGateway) {
        self.gateway = gateway
    }

    func refresh(recalculate: Bool = false) async {
        snapshot = await gateway.snapshot(refreshCounts: recalculate)
    }

    func monitor(intervalNanoseconds: UInt64 = 1_000_000_000) async {
        var first = true
        while !Task.isCancelled {
            await refresh(recalculate: first)
            first = false
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
    }

    func runOnce() async {
        await gateway.runProcessingScan()
        await refresh()
    }
}
