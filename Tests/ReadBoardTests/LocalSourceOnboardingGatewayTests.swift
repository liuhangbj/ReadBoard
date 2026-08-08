import XCTest
import ReadBoardContract
@testable import ReadBoard

final class LocalSourceOnboardingGatewayTests: XCTestCase {
    private let singleIdentifier = "https://test.invalid/onboarding-single.xml"
    private let importIdentifier = "https://test.invalid/onboarding-import.xml"
    private let folderName = "Onboarding Gateway 文件夹"

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

    func testCreateRejectsDuplicateAndBatchImportCreatesFolder() async throws {
        let gateway = LocalSourceOnboardingGateway()
        let created = try await gateway.create(request: SourceCreationRequest(
            identifier: singleIdentifier,
            name: "单源录入",
            sourceType: "article",
            policy: .init(autoScore: true),
            fetchMode: .summary,
            refreshAfterCreation: false))
        XCTAssertGreaterThan(created.sourceID, 0)
        XCTAssertEqual(Database.shared.scalarString(
            "SELECT stype FROM content_source WHERE id=?", params: [created.sourceID]), "rss")

        do {
            _ = try await gateway.create(request: SourceCreationRequest(
                identifier: singleIdentifier,
                name: "重复源",
                sourceType: "article",
                fetchMode: .summary,
                refreshAfterCreation: false))
            XCTFail("重复源应返回 typed error")
        } catch let error as SourceOnboardingGatewayError {
            guard case .duplicateSource(let sourceID) = error else {
                return XCTFail("应返回 duplicateSource，实际为 \(error)")
            }
            XCTAssertEqual(sourceID, created.sourceID)
        }

        let imported = try await gateway.importSources(items: [
            SourceBatchImportItem(
                id: "import-1",
                name: "批量录入",
                identifier: importIdentifier,
                sourceType: "article",
                folderName: folderName,
                policy: .init(autoSummarize: true),
                fetchMode: .defuddle),
            SourceBatchImportItem(
                id: "import-duplicate",
                name: "批量重复",
                identifier: importIdentifier,
                sourceType: "article",
                folderName: folderName,
                fetchMode: .defuddle)
        ], refreshAfterCreation: false)

        XCTAssertEqual(imported.createdSourceIDs.count, 1)
        XCTAssertEqual(imported.skippedCount, 1)
        XCTAssertEqual(Database.shared.scalarInt(
            "SELECT COUNT(*) FROM folder WHERE name=?", params: [folderName]), 1)
    }

    func testUnsupportedPlatformImportReturnsTypedError() async throws {
        do {
            _ = try await LocalSourceOnboardingGateway()
                .platformSubscriptions(platform: "unsupported")
            XCTFail("不支持的平台应失败")
        } catch let error as SourceOnboardingGatewayError {
            guard case .unsupportedSource = error else {
                return XCTFail("应返回 unsupportedSource")
            }
        }
    }

    private func cleanup() {
        Database.shared.execute(
            "DELETE FROM content_source WHERE identifier IN (?, ?)",
            params: [singleIdentifier, importIdentifier])
        Database.shared.execute("DELETE FROM folder WHERE name=?", params: [folderName])
    }
}
