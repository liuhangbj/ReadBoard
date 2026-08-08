import XCTest
import ReadBoardContract
@testable import ReadBoard

final class LocalSourceManagementGatewayTests: XCTestCase {
    private let folderName = "Gateway 文件夹 9261001"
    private let renamedFolderName = "Gateway 文件夹 9261001 已重命名"

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

    private func cleanup() {
        Database.shared.execute(
            "DELETE FROM folder WHERE name IN (?, ?)",
            params: [folderName, renamedFolderName])
    }
}
