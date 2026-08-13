import Foundation
import XCTest
import ReadBoardContract
@testable import ReadBoard

final class LocalSourceManagementGatewayTests: XCTestCase {
    private let folderName = "Gateway 文件夹 9261001"
    private let renamedFolderName = "Gateway 文件夹 9261001 已重命名"
    private let folderID: Int64 = 9_261_001
    private let sourceIDs: [Int64] = [9_261_011, 9_261_012]

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向隔离临时数据库")
        }
        XCTAssertTrue(Database.shared.open())
        cleanup()
    }

    override func tearDownWithError() throws {
        if ProcessInfo.processInfo.environment["READBOARD_DB"] != nil { cleanup() }
    }

    func testFolderLifecycleUsesSourceCommandBoundary() async throws {
        let gateway = LocalSourceManagementGateway()
        let created = try await gateway.createFolder(name: "  \(folderName)  ")
        XCTAssertEqual(created.message, "已创建文件夹")

        let folderID = Int64(Database.shared.scalarInt(
            "SELECT id FROM folder WHERE name=?", params: [folderName]) ?? 0)
        XCTAssertGreaterThan(folderID, 0)

        _ = try await gateway.rename(
            scope: SourceScope(kind: .folder, id: folderID),
            name: renamedFolderName)
        XCTAssertEqual(
            Database.shared.scalarString("SELECT name FROM folder WHERE id=?", params: [folderID]),
            renamedFolderName)

        _ = try await gateway.remove(scope: SourceScope(kind: .folder, id: folderID))
        XCTAssertEqual(
            Database.shared.scalarInt("SELECT COUNT(*) FROM folder WHERE id=?", params: [folderID]),
            0)
    }

    func testFolderSettingsUpdateEveryChildSource() async throws {
        XCTAssertTrue(Database.shared.execute(
            "INSERT INTO folder(id, name, config) VALUES (?, ?, '{}')",
            params: [folderID, folderName]))
        for (index, sourceID) in sourceIDs.enumerated() {
            XCTAssertTrue(Database.shared.execute("""
                INSERT INTO content_source(
                    id, stype, name, identifier, enabled, config, folder_id)
                VALUES (?, 'rss', ?, ?, 1, ?, ?)
                """, params: [
                    sourceID,
                    "批量设置源 \(index)",
                    "https://test.invalid/gateway-folder-\(index)",
                    "{\"auto_summarize\":false,\"fetch_mode\":\"feed_full\",\"fetch_mode_auto\":true,\"fetch_interval_min\":15,\"max_keep\":0}",
                    folderID
                ]))
        }
        await MainActor.run { SourceStore.shared.reload() }

        let gateway = LocalSourceManagementGateway()
        let scope = SourceScope(kind: .folder, id: folderID)
        try await gateway.setPolicy(scope: scope, key: .summarize, enabled: true)
        try await gateway.setFetchMode(scope: scope, mode: .summary)
        try await gateway.setFetchInterval(scope: scope, minutes: 60)
        try await gateway.setMaximumRetainedContent(scope: scope, count: 200)

        for sourceID in sourceIDs {
            let raw = try XCTUnwrap(Database.shared.scalarString(
                "SELECT config FROM content_source WHERE id=?",
                params: [sourceID]))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(raw.utf8)) as? [String: Any])
            XCTAssertEqual(object["auto_summarize"] as? Bool, true)
            XCTAssertEqual(object["fetch_mode"] as? String, "summary")
            XCTAssertEqual(object["fetch_mode_auto"] as? Bool, false)
            XCTAssertEqual(object["fetch_interval_min"] as? Int, 60)
            XCTAssertEqual(object["max_keep"] as? Int, 200)
        }
    }

    private func cleanup() {
        for sourceID in sourceIDs {
            Database.shared.execute("DELETE FROM content_source WHERE id=?", params: [sourceID])
        }
        Database.shared.execute("DELETE FROM folder WHERE id=?", params: [folderID])
        Database.shared.execute(
            "DELETE FROM folder WHERE name IN (?, ?)",
            params: [folderName, renamedFolderName])
    }
}
