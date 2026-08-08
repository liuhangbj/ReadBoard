import XCTest
import ReadBoardContract
@testable import ReadBoard

final class LocalExportGatewayTests: XCTestCase {
    private let ruleName = "Gateway 导出规则 9262001"

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

    func testRuleLifecyclePreservesTypedFields() async throws {
        let gateway = LocalExportGateway()
        let saved = try await gateway.save(rule: ExportRuleDTO(
            name: ruleName,
            criteria: .init(minimumScore: 75, requireSummary: true),
            trigger: "scheduled",
            artifact: "summary_original",
            subfolderTemplate: "Gateway/{year}",
            writePolicy: "versioned",
            scheduleInterval: "weekly"))

        XCTAssertGreaterThan(saved.id, 0)
        XCTAssertEqual(saved.criteria.minimumScore, 75)
        XCTAssertEqual(saved.artifact, "summary_original")
        XCTAssertEqual(saved.scheduleInterval, "weekly")
        let rulesAfterSave = try await gateway.rules()
        let stats = try await gateway.stats(ruleID: saved.id)
        XCTAssertTrue(rulesAfterSave.contains(where: { $0.id == saved.id }))
        XCTAssertEqual(stats, .init(delivered: 0, failed: 0))

        try await gateway.delete(ruleID: saved.id)
        let rulesAfterDelete = try await gateway.rules()
        XCTAssertFalse(rulesAfterDelete.contains(where: { $0.id == saved.id }))
    }

    private func cleanup() {
        for row in Database.shared.queryRows(
            "SELECT id FROM export_rule WHERE name=?", params: [ruleName]) {
            if let id = row["id"].flatMap(Int64.init) {
                ExportService.shared.deleteRule(id: id)
            }
        }
    }
}
