import XCTest
@testable import ReadBoardContract

final class ContentDetailContractTests: XCTestCase {
    func testDetailRoundTripsWithoutDatabaseOrTransportTypes() throws {
        let detail = ContentDetail(
            id: 42,
            contentMarkdown: "# 原文",
            translatedMarkdown: "# 译文",
            transcriptMarkdown: "转录稿",
            translatedTitle: "中文标题",
            audioURL: "https://example.com/audio.mp3",
            videoID: "video-42",
            score: 88,
            summary: "摘要"
        )

        let data = try JSONEncoder().encode(detail)
        XCTAssertEqual(try JSONDecoder().decode(ContentDetail.self, from: data), detail)
    }

    func testMissingContentIsATypedContractError() {
        let error = ContentDetailGatewayError.contentNotFound(404)
        XCTAssertEqual(error.errorDescription, "内容不存在或已被删除")
    }
}
