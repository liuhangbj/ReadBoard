import XCTest
import ReadBoardContract
@testable import ReadBoard

final class LocalSourceCatalogGatewayTests: XCTestCase {
    private let sourceID: Int64 = 9_263_001
    private let folderID: Int64 = 9_263_002
    private let contentID: Int64 = 9_263_003

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向隔离临时数据库")
        }
        XCTAssertTrue(Database.shared.open())
        cleanup()
        XCTAssertTrue(Database.shared.execute(
            "INSERT INTO folder(id, name, config) VALUES (?, '快照文件夹', '{}')",
            params: [folderID]))
        XCTAssertTrue(Database.shared.execute("""
            INSERT INTO content_source(
                id, stype, name, identifier, enabled, config, folder_id, last_fetched_at)
            VALUES (?, 'bilibili', '快照测试源', '9263001', 1, ?, ?, datetime('now'));
            """, params: [
                sourceID,
                "{\"auto_score\":true,\"auto_summarize\":true,\"fetch_mode\":\"bilibili_subtitle\",\"fetch_interval_min\":30,\"max_keep\":200}",
                folderID
            ]))
        XCTAssertTrue(Database.shared.execute("""
            INSERT INTO content(id, source_id, ctype, guid, source, title, url)
            VALUES (?, ?, 'video', 'catalog-gateway', 'bilibili', '快照内容', 'https://test.invalid/catalog');
            """, params: [contentID, sourceID]))
    }

    override func tearDownWithError() throws {
        if ProcessInfo.processInfo.environment["READBOARD_DB"] != nil { cleanup() }
    }

    func testSnapshotNormalizesDatabaseConfiguration() async throws {
        let snapshot = try await LocalSourceCatalogGateway(database: .shared).snapshot()
        let source = try XCTUnwrap(snapshot.sources.first { $0.id == sourceID })

        XCTAssertEqual(source.folderID, folderID)
        XCTAssertEqual(source.fetchMode, .bilibiliSubtitle)
        XCTAssertEqual(source.fetchIntervalMinutes, 30)
        XCTAssertEqual(source.maximumRetainedContent, 200)
        XCTAssertEqual(source.contentCount, 1)
        XCTAssertTrue(source.policy.autoScore)
        XCTAssertTrue(source.policy.autoSummarize)
        XCTAssertTrue(source.transcribable)
        XCTAssertEqual(snapshot.folders.first { $0.id == folderID }?.name, "快照文件夹")
    }

    private func cleanup() {
        Database.shared.execute("DELETE FROM content WHERE id=?", params: [contentID])
        Database.shared.execute("DELETE FROM content_source WHERE id=?", params: [sourceID])
        Database.shared.execute("DELETE FROM folder WHERE id=?", params: [folderID])
    }
}
