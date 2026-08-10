import Foundation
import ReadBoardContract
import ReadBoardUI
import XCTest

final class ReadBoardUITests: XCTestCase {
    func testDesktopColumnsKeepAStableSystemSplitLayout() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardUI/ReadBoardLibraryComponents.swift"),
            encoding: .utf8)
        let bridge = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardUI/ReadBoardResizableColumns.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("ReadBoardResizableColumns("))
        XCTAssertTrue(source.contains("@AppStorage(\"ReadBoard.Library.ListDetail.leadingWidth\")"))
        XCTAssertTrue(source.contains("leadingWidth: $persistedListWidth"))
        XCTAssertTrue(bridge.contains("NSSplitViewDelegate"))
        XCTAssertTrue(bridge.contains("constrainSplitPosition"))
        XCTAssertTrue(bridge.contains("onDividerDragEnded"))
        XCTAssertTrue(bridge.contains("leadingWidth.wrappedValue = Double(width)"))
        XCTAssertFalse(source.contains("HSplitView {"))
        XCTAssertEqual(ReadBoardLibraryColumnMetrics.listMaximum, .greatestFiniteMagnitude)
    }

    func testMultipleImagesRemainIndependentRenderBlocks() {
        let markdown = """
        第一段

        ![one](https://example.com/1.jpg) ![two](https://example.com/2.jpg)

        第二段
        """

        let blocks = ReadBoardMarkdownParser.parse(markdown)
        XCTAssertEqual(blocks.count, 4)
        guard case .image(let firstAlt, _) = blocks[1],
              case .image(let secondAlt, _) = blocks[2] else {
            return XCTFail("两张图片应拆成两个独立渲染块")
        }
        XCTAssertEqual(firstAlt, "one")
        XCTAssertEqual(secondAlt, "two")
    }

    func testTextSelectionFlowStopsAtMediaBlocks() {
        let markdown = """
        # 标题

        第一段

        - 列表

        ![image](https://example.com/image.jpg)

        第二段
        """

        XCTAssertEqual(
            ReadBoardMarkdownBodyView.selectionUnitBlockCounts(markdown: markdown),
            [3, 1, 1]
        )
    }

    func testVeryLongMarkdownIsSplitIntoRenderableTextUnitsWithoutTruncation() {
        let text = String(repeating: "这是一段需要完整显示的长文章内容。", count: 4_000)
        let counts = ReadBoardMarkdownBodyView.selectionUnitCharacterCounts(markdown: text)

        XCTAssertGreaterThan(counts.count, 1)
        XCTAssertTrue(counts.allSatisfy { $0 <= 12_000 })
        XCTAssertEqual(counts.reduce(0, +), text.count)
    }

    func testArticleDocumentOwnsModeSelectionForBothClients() {
        let summary = ContentSummary(
            id: 42, contentType: "video", source: "bilibili", sourceType: "bilibili",
            sourceID: 1, sourceName: "测试来源", title: "Original", author: "Author",
            url: "https://www.bilibili.com/video/BV1", language: "en", publishedAt: nil,
            excerpt: nil, score: 80, summary: "摘要", fetchStatus: 1,
            isRead: false, isStarred: false, imageURL: nil, hasTranslation: true,
            hasTranscript: false, isMedia: true, translatedHead: nil,
            translatedTitle: "译文标题", hasFulltext: true, hasExport: false,
            hasUnmetProcessing: false, accessState: nil)
        let detail = ContentDetail(
            id: 42, contentMarkdown: "original", translatedMarkdown: "translated",
            transcriptMarkdown: nil, translatedTitle: nil, audioURL: nil, videoID: "BV1",
            score: nil, summary: nil)

        let document = ReadBoardArticleDocument(summary: summary, detail: detail)
        XCTAssertEqual(document.availableModes, [.original, .translated])
        XCTAssertEqual(document.preferredMode, .translated)
        XCTAssertEqual(document.markdown(for: .translated), "translated")
        XCTAssertEqual(document.translatedTitle, "译文标题")
        XCTAssertEqual(document.kind, .video)
    }

    func testLibraryPresentationIsIdenticalForLocalAndRemoteRows() {
        let summary = ContentSummary(
            id: 7, contentType: "video", source: "legacy", sourceType: "bilibili",
            sourceID: 2, sourceName: "测试视频", title: "Original", author: nil,
            url: "https://www.bilibili.com/video/BV7", language: nil, publishedAt: 1_000,
            excerpt: "简介", score: 91, summary: "摘要", fetchStatus: 1,
            isRead: false, isStarred: true, imageURL: nil, hasTranslation: true,
            hasTranscript: true, isMedia: true,
            translatedHead: "\n## 共享标题\n正文", translatedTitle: nil,
            hasFulltext: true, hasExport: true, hasUnmetProcessing: false,
            accessState: "upowerEarlyAccess")

        let presentation = ReadBoardLibraryItemPresentation(item: summary)
        XCTAssertEqual(presentation.displayTitle, "共享标题")
        XCTAssertEqual(presentation.platformIcon, "tv.fill")
        XCTAssertEqual(
            presentation.badges.map(\.text),
            ["充电抢先看", "全文", "评分 91", "摘要", "翻译", "转录"])
        XCTAssertEqual(
            presentation.formattedDate(
                style: .relative,
                now: Date(timeIntervalSince1970: 4_600)),
            "1 小时前")
    }

    func testLibraryCollectionsOwnSharedDefaultFiltersAndCounts() {
        let counts = LibraryCountsSnapshot(
            total: 100, unread: 7, pending: 3, pendingUnread: 1,
            exported: 9, exportedUnread: 2, articles: 60, articleUnread: 4,
            podcasts: 25, podcastUnread: 2, videos: 15, videoUnread: 1)

        XCTAssertEqual(ReadBoardLibraryCollection.unread.initialReadFilter, .unread)
        XCTAssertEqual(ReadBoardLibraryCollection.podcasts.initialCategoryFilter, .podcast)
        XCTAssertEqual(ReadBoardLibraryCollection.articles.count(in: counts), 60)
        let articles = ReadBoardLibraryCollection.articles.countPair(in: counts)
        XCTAssertEqual(articles?.unread, 4)
        XCTAssertEqual(articles?.total, 60)
        let exported = ReadBoardLibraryCollection.exported.countPair(in: counts)
        XCTAssertEqual(exported?.unread, 2)
        XCTAssertEqual(exported?.total, 9)
        XCTAssertNil(ReadBoardLibraryCollection.starred.count(in: counts))
    }

    func testLibraryQueryStateBuildsTheSameContractQueryForBothClients() {
        var state = ReadBoardLibraryQueryState(collection: .podcasts)
        state.searchText = "  energy  "
        state.readFilter = .unread
        state.sortOption = .oldest
        state.minimumScore = 70
        state.includeUnscored = true
        state.processing[.summary] = .complete

        let query = state.contentQuery(cursor: "next", pageSize: 75)
        XCTAssertEqual(state.identity.search, "energy")
        XCTAssertTrue(state.hasActiveFilter)
        XCTAssertEqual(query.filter.category, .podcast)
        XCTAssertEqual(query.filter.readState, .unread)
        XCTAssertEqual(query.filter.keyword, "energy")
        XCTAssertEqual(query.filter.minimumScore, 70)
        XCTAssertTrue(query.filter.includeUnscored)
        XCTAssertEqual(query.filter.processing, [
            ProcessingCriterion(kind: .summary, match: .complete),
        ])
        XCTAssertEqual(query.sort, .oldest)
        XCTAssertEqual(query.pageSize, 75)
        XCTAssertEqual(query.cursor, "next")

        state.reset()
        XCTAssertEqual(state.categoryFilter, .podcast)
        XCTAssertEqual(state.readFilter, .all)
        XCTAssertEqual(state.minimumScore, 0)
        XCTAssertTrue(state.processing.isEmpty)
        XCTAssertFalse(state.hasActiveFilter)
        XCTAssertEqual(state.emptyPresentation.title, "暂无内容")
    }

    func testLibraryPaginationIgnoresStaleRequestsAndDeduplicatesItems() {
        struct Item: Identifiable, Equatable {
            let id: Int
        }

        var state = ReadBoardLibraryPaginationState()
        let stale = state.beginReload()
        let current = state.beginReload()
        state.finishReload(stale, nextCursor: "stale")
        XCTAssertTrue(state.isInitialLoading)
        XCTAssertNil(state.nextCursor)

        state.finishReload(current, nextCursor: "page-2")
        XCTAssertFalse(state.isInitialLoading)
        XCTAssertTrue(state.hasMore)

        let pageRequest = state.beginLoadingMore()
        XCTAssertEqual(pageRequest?.cursor, "page-2")
        XCTAssertNil(state.beginLoadingMore())
        state.finishLoadingMore(pageRequest!.token, nextCursor: nil)
        XCTAssertFalse(state.hasMore)

        let merged = ReadBoardLibraryPaginationState.appendingUnique(
            [Item(id: 2), Item(id: 3)], to: [Item(id: 1), Item(id: 2)])
        XCTAssertEqual(merged, [Item(id: 1), Item(id: 2), Item(id: 3)])
    }

    func testLibrarySelectionOwnsReconciliationAndAdjacentNavigation() {
        var selection = ReadBoardLibrarySelectionState(selectedID: 20)
        XCTAssertTrue(selection.isSelected(20))
        XCTAssertEqual(selection.adjacentID(in: [10, 20, 30], offset: 1), 30)
        XCTAssertEqual(selection.adjacentID(in: [10, 20, 30], offset: -1), 10)

        selection.select(10)
        XCTAssertNil(selection.adjacentID(in: [10, 20, 30], offset: -1))
        selection.select(30)
        XCTAssertNil(selection.adjacentID(in: [10, 20, 30], offset: 1))
        selection.select(20)

        XCTAssertFalse(selection.reconcile(
            availableIDs: [10, 30], retention: .preserveReading))
        XCTAssertEqual(selection.selectedID, 20)

        XCTAssertTrue(selection.reconcile(
            availableIDs: [10, 30], retention: .requireVisibleItem))
        XCTAssertNil(selection.selectedID)
        XCTAssertEqual(selection.adjacentID(in: [10, 20, 30], offset: 1), 10)
        XCTAssertEqual(selection.adjacentID(in: [10, 20, 30], offset: -1), 30)
    }
}
