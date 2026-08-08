import XCTest
import ReadBoardContract
@testable import ReadBoard

final class LocalReaderGatewayTests: XCTestCase {
    private let sourceID: Int64 = 9_260_001
    private let contentIDs: [Int64] = [9_260_011, 9_260_012, 9_260_013]
    private let exportRuleID: Int64 = 9_260_021

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向隔离临时数据库")
        }
        let db = Database.shared
        XCTAssertTrue(db.open())
        cleanup()
        XCTAssertTrue(db.execute("""
            INSERT INTO content_source(id, stype, name, identifier, config, enabled)
            VALUES (?, 'rss', 'Gateway 测试源', ?, '{}', 1);
            """, params: [sourceID, "https://test.invalid/gateway-source-\(sourceID)"]))
        for (index, id) in contentIDs.enumerated() {
            XCTAssertTrue(db.execute("""
                INSERT INTO content(
                    id, source_id, ctype, guid, source, title, url, published_at,
                    excerpt, fetch_status, read_at, starred, is_duplicate)
                VALUES (?, ?, 'article', ?, 'rss', ?, ?, ?, ?, 2, NULL, 0, 0);
                """, params: [
                    id, sourceID, "gateway-guid-\(id)", "Gateway 内容 \(index)",
                    "https://test.invalid/gateway/\(id)",
                    "2026-08-0\(index + 1)T00:00:00Z", "摘要 \(index)"
                ]))
        }
        XCTAssertTrue(db.execute("""
            INSERT INTO export_rule(id, name, enabled, criteria, trigger_on, target, target_config)
            VALUES (?, 'Gateway 导出筛选测试', 1, '{}', 'manual', 'obsidian', '{}');
            """, params: [exportRuleID]))
        XCTAssertTrue(db.execute("""
            INSERT INTO export_record(rule_id, content_id, artifact, revision, status)
            VALUES (?, ?, 'original', 1, 'delivered');
            """, params: [exportRuleID, contentIDs[0]]))
    }

    override func tearDownWithError() throws {
        if ProcessInfo.processInfo.environment["READBOARD_DB"] != nil { cleanup() }
    }

    func testOpaqueCursorPaginatesAndRejectsAnotherQuery() async throws {
        let gateway = LocalReaderGateway(database: .shared)
        let filter = ContentFilter(sourceID: sourceID)
        let first = try await gateway.page(ContentQuery(
            filter: filter, sort: .newest, pageSize: 2))

        XCTAssertEqual(first.items.map(\.id), [contentIDs[2], contentIDs[1]])
        let cursor = try XCTUnwrap(first.nextCursor)

        let second = try await gateway.page(ContentQuery(
            filter: filter, sort: .newest, pageSize: 2, cursor: cursor))
        XCTAssertEqual(second.items.map(\.id), [contentIDs[0]])
        XCTAssertNil(second.nextCursor)

        do {
            _ = try await gateway.page(ContentQuery(
                filter: filter, sort: .oldest, pageSize: 2, cursor: cursor))
            XCTFail("另一个查询不能复用旧游标")
        } catch let error as LibraryGatewayError {
            XCTAssertEqual(error, .invalidCursor)
        }
    }

    func testStateMutationsAreIdempotentAndBulkScopeMatchesFilter() async throws {
        let gateway = LocalReaderGateway(database: .shared)
        let contentID = contentIDs[0]

        let firstStar = try await gateway.setStarred(contentID: contentID, isStarred: true)
        let secondStar = try await gateway.setStarred(contentID: contentID, isStarred: true)
        XCTAssertTrue(firstStar.isStarred)
        XCTAssertTrue(secondStar.isStarred)
        XCTAssertEqual(Database.shared.scalarInt(
            "SELECT starred FROM content WHERE id=?", params: [contentID]), 1)

        _ = try await gateway.setRead(contentID: contentID, isRead: false)
        let readSummary = try await gateway.markRead(filter: ContentFilter(sourceID: sourceID))
        XCTAssertEqual(readSummary.affectedCount, 3)
        XCTAssertEqual(Database.shared.scalarInt("""
            SELECT COUNT(*) FROM content
            WHERE source_id=? AND read_at IS NOT NULL;
            """, params: [sourceID]), 3)
    }

    func testBulkReadHonorsExportedFilter() async throws {
        let gateway = LocalReaderGateway(database: .shared)

        let summary = try await gateway.markRead(filter: ContentFilter(
            sourceID: sourceID,
            exportedOnly: true
        ))

        XCTAssertEqual(summary.affectedCount, 1)
        XCTAssertEqual(Database.shared.scalarInt(
            "SELECT read_at IS NOT NULL FROM content WHERE id=?",
            params: [contentIDs[0]]), 1)
        XCTAssertEqual(Database.shared.scalarInt("""
            SELECT COUNT(*) FROM content
            WHERE source_id=? AND id<>? AND read_at IS NOT NULL;
            """, params: [sourceID, contentIDs[0]]), 0)
    }

    private func cleanup() {
        let db = Database.shared
        db.execute("DELETE FROM export_rule WHERE id=?", params: [exportRuleID])
        for id in contentIDs {
            db.execute("DELETE FROM content_job WHERE content_id=?", params: [id])
            db.execute("DELETE FROM content WHERE id=?", params: [id])
        }
        db.execute("DELETE FROM content_source WHERE id=?", params: [sourceID])
    }
}
