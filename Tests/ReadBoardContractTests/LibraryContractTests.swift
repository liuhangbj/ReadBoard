import XCTest
@testable import ReadBoardContract

final class LibraryContractTests: XCTestCase {
    func testQueryAndPageAreCodableWithoutTransportSpecificTypes() throws {
        let query = ContentQuery(
            filter: ContentFilter(
                sourceID: 42,
                minimumScore: 70,
                readState: .unread,
                keyword: "架构",
                processing: [
                    ProcessingCriterion(kind: .summary, match: .complete),
                    ProcessingCriterion(kind: .translate, match: .incomplete)
                ]
            ),
            sort: .score,
            pageSize: 50,
            cursor: "opaque"
        )
        let data = try JSONEncoder().encode(query)
        XCTAssertEqual(try JSONDecoder().decode(ContentQuery.self, from: data), query)

        let item = ContentSummary(
            id: 1, contentType: "article", source: "rss", sourceType: "wechat",
            sourceID: 42, sourceName: "测试源", title: "长期契约", author: nil,
            url: "https://example.com/1", language: "zh", publishedAt: 1_700_000_000,
            excerpt: "摘要", score: 90, summary: "总结", fetchStatus: 2,
            isRead: false, isStarred: true, imageURL: nil, hasTranslation: true,
            hasTranscript: false, isMedia: false, translatedHead: nil,
            translatedTitle: nil, hasFulltext: true, hasExport: false,
            hasUnmetProcessing: false, accessState: nil
        )
        let page = ContentPage(items: [item], nextCursor: "next")
        let pageData = try JSONEncoder().encode(page)
        XCTAssertEqual(try JSONDecoder().decode(ContentPage.self, from: pageData), page)
    }

    func testMutationContractUsesExplicitTargetState() {
        let state = ContentState(
            contentID: 7, isRead: true, isStarred: false, updatedAt: 1_700_000_000)
        XCTAssertTrue(state.isRead)
        XCTAssertFalse(state.isStarred)
    }
}
