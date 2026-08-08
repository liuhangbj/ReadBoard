import XCTest
import ReadBoardContract
@testable import ReadBoard

final class LocalContentDetailGatewayTests: XCTestCase {
    private let sourceID: Int64 = 9_261_001
    private let contentID: Int64 = 9_261_011

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向隔离临时数据库")
        }
        let db = Database.shared
        XCTAssertTrue(db.open())
        cleanup()
        XCTAssertTrue(db.execute("""
            INSERT INTO content_source(id, stype, name, identifier, config, enabled)
            VALUES (?, 'podcast', '详情 Gateway 测试源', ?,
                    '{"auto_score":true,"auto_translate":false,"auto_transcribe":true,"auto_summarize":false}', 1);
            """, params: [sourceID, "https://test.invalid/detail-source-\(sourceID)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content(
                id, source_id, ctype, guid, source, title, url, excerpt, fetch_status,
                content_md, llm_translated_md, llm_transcript_md,
                llm_title_translated, llm_score, llm_summary, meta)
            VALUES (?, ?, 'podcast', ?, 'podcast', '详情契约测试', ?, '简介', 4,
                    '# 原文', '# 译文', '转录稿', '中文标题', 91, '摘要',
                    '{"audio_url":"https://example.com/audio.mp3","video_id":"video-1"}');
            """, params: [
                contentID, sourceID, "detail-guid-\(contentID)",
                "https://test.invalid/detail/\(contentID)"
            ]))
    }

    override func tearDownWithError() throws {
        if ProcessInfo.processInfo.environment["READBOARD_DB"] != nil { cleanup() }
    }

    func testLoadsCompleteReaderDetailAndPolicy() async throws {
        let detail = try await LocalContentDetailGateway(database: .shared)
            .detail(contentID: contentID)

        XCTAssertEqual(detail.id, contentID)
        XCTAssertEqual(detail.contentMarkdown, "# 原文")
        XCTAssertEqual(detail.translatedMarkdown, "# 译文")
        XCTAssertEqual(detail.transcriptMarkdown, "转录稿")
        XCTAssertEqual(detail.translatedTitle, "中文标题")
        XCTAssertEqual(detail.audioURL, "https://example.com/audio.mp3")
        XCTAssertEqual(detail.videoID, "video-1")
        XCTAssertEqual(detail.score, 91)
        XCTAssertEqual(detail.summary, "摘要")
    }

    func testMissingContentReturnsTypedError() async throws {
        do {
            _ = try await LocalContentDetailGateway(database: .shared)
                .detail(contentID: contentID + 1)
            XCTFail("不存在的内容不应返回空详情")
        } catch let error as ContentDetailGatewayError {
            XCTAssertEqual(error, .contentNotFound(contentID + 1))
        }
    }

    private func cleanup() {
        let db = Database.shared
        db.execute("DELETE FROM content_job WHERE content_id=?", params: [contentID])
        db.execute("DELETE FROM content WHERE id=?", params: [contentID])
        db.execute("DELETE FROM content_source WHERE id=?", params: [sourceID])
    }
}
