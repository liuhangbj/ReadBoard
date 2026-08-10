import Foundation
import XCTest

final class CoreReaderParityGuardTests: XCTestCase {
    func testCoreReaderShellKeepsEstablishedDesktopBehaviors() throws {
        let appSource = try sourceText("Sources/ReadBoard/ReadBoardApp.swift")
        XCTAssertTrue(appSource.contains("ReadBoardDesktopMainFeatureView("))
        XCTAssertFalse(appSource.contains("ContentView(services: services)"))

        let source = try [
            "Sources/ReadBoardFeatures/Desktop/ReadBoardDesktopMainFeatureView.swift",
            "Sources/ReadBoardFeatures/Library/ReadBoardLibraryFeatureView.swift",
            "Sources/ReadBoardFeatures/Library/ReadBoardLibraryNavigation.swift",
            "Sources/ReadBoardFeatures/Reading/ReadBoardArticleDetailFeatureView.swift",
        ].map(sourceText).joined(separator: "\n")
        let requiredSentinels = [
            "ReadBoardLibraryDesktopColumns",
            "ReadBoardLibrarySearchField",
            "processingFilterChip(.fulltext)",
            "processingFilterChip(.score)",
            "processingFilterChip(.summary)",
            "@AppStorage(\"reading.viewMode\")",
            "@AppStorage(\"reading.mediaTab\")",
            ".keyboardShortcut(\"j\", modifiers: [])",
            ".keyboardShortcut(\"k\", modifiers: [])",
            ".keyboardShortcut(.space, modifiers: [])",
            "await model.selectAdjacent(offset: 1)",
            "ReadBoardArticleDetailFeatureView",
        ]

        for sentinel in requiredSentinels {
            XCTAssertTrue(
                source.contains(sentinel),
                "Core reader behavior sentinel disappeared: \(sentinel)")
        }
    }

    func testCoreReaderModelKeepsCountsAndSelectionActions() throws {
        let source = try sourceText(
            "Sources/ReadBoardFeatures/Library/ReadBoardLibraryFeatureModel.swift")
        let requiredSentinels = [
            "public private(set) var navigationSnapshot: LibrarySnapshot?",
            "public private(set) var selectedItem: ContentSummary?",
            "public func setRead(",
            "public func setStarred(",
            "public func markCurrentLocationRead()",
            "public func selectAdjacent(",
            "stateMutationGeneration",
            "ReadBoardLibraryPaginationState.appendingUnique",
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
