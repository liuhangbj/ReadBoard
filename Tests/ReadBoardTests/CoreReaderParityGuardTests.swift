import Foundation
import XCTest

final class CoreReaderParityGuardTests: XCTestCase {
    func testCoreReaderShellKeepsEstablishedDesktopBehaviors() throws {
        let source = try sourceText("Sources/ReadBoard/ContentView.swift")
        let requiredSentinels = [
            "navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)",
            "navigationSplitViewColumnWidth(min: 280, ideal: 380, max: 640)",
            "sidebarCount(unread: vm.totalUnread, total: vm.totalCount)",
            "sidebarCount(unread: vm.totalPendingUnread, total: vm.totalPending)",
            "sidebarCount(unread: vm.totalExportedUnread, total: vm.totalExported)",
            "@AppStorage(\"reading.viewMode\")",
            "@AppStorage(\"reading.mediaTab\")",
            ".popover(isPresented: $showLayoutPopover",
            ".keyboardShortcut(\"j\", modifiers: [])",
            ".keyboardShortcut(\"k\", modifiers: [])",
            ".keyboardShortcut(.space, modifiers: [])",
            "onPrev: { vm.selectPrev() }, onNext: { vm.selectNext() }",
            "UserDefaults.standard.set(Array(expandedFolders), forKey: Self.expandedKey)",
        ]

        for sentinel in requiredSentinels {
            XCTAssertTrue(
                source.contains(sentinel),
                "Core reader behavior sentinel disappeared: \(sentinel)")
        }
    }

    func testCoreReaderModelKeepsCountsAndSelectionActions() throws {
        let source = try sourceText("Sources/ReadBoard/ContentViewModel.swift")
        let requiredSentinels = [
            "@Published var totalUnread: Int = 0",
            "@Published var articleUnread: Int = 0",
            "@Published var podcastUnread: Int = 0",
            "@Published var videoUnread: Int = 0",
            "func toggleRead(_ item: ContentItem)",
            "func toggleStar(_ item: ContentItem)",
            "func markAllRead()",
            "func selectNext()",
            "func selectPrev()",
        ]

        for sentinel in requiredSentinels {
            XCTAssertTrue(
                source.contains(sentinel),
                "Core reader state sentinel disappeared: \(sentinel)")
        }
    }

    private func sourceText(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}
