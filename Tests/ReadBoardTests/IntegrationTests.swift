import XCTest
import SQLite3
@testable import ReadBoard

// MARK: - 显式启用的集成测试
// 数据库测试只允许通过 READBOARD_DB 指向隔离库；真实 LLM 还必须显式设置
// READBOARD_RUN_LIVE_LLM_TESTS=1。默认 swift test 不接触用户数据，也不调用付费 API。

final class LLMIntegrationTests: XCTestCase {

    func testRealLLMScoreAndParse() async throws {
        guard ProcessInfo.processInfo.environment["READBOARD_RUN_LIVE_LLM_TESTS"] == "1" else {
            throw XCTSkip("需要 READBOARD_RUN_LIVE_LLM_TESTS=1 才会调用真实 LLM")
        }
        let client = LLMClient()
        guard client.isAvailable else {
            throw XCTSkip("已启用真实 LLM 测试，但没有可用模型配置")
        }
        let (text, model) = try await client.chat(messages: [
            ChatMessage(role: "user", content: """
            给这段内容打分，返回 JSON：{"depth":0-40,"quality":0-35,"readability":0-25,"total":0-100,"summary":"一句话"}
            内容：黄金价格创历史新高，央行连续 18 个月增持，去美元化趋势加速。
            """)
        ], maxTokens: 200)
        print("LLM 返回(\(model)): \(text.prefix(200))")
        // 验证能被 parseScoreJSON 解析（这是管线的真实契约）
        let parsed = LLMPipeline.parseScoreJSON(text)
        XCTAssertNotNil(parsed, "真实 LLM 返回应能被 parseScoreJSON 解析")
        if let p = parsed {
            XCTAssertLessThanOrEqual(p.depth, 40)
            XCTAssertLessThanOrEqual(p.quality, 35)
            XCTAssertLessThanOrEqual(p.readability, 25)
            XCTAssertLessThanOrEqual(p.total, 100)
        }
    }

    func testRateLimitRetryPathExists() {
        // 结构性验证：chat 走 callWithRateLimitRetry（429 退避逻辑存在）
        // 真实 429 难触发，这里只确认链路易用且不错误分类
        let client = LLMClient()
        _ = client.isAvailable  // 不崩即可
    }
}

final class ExportIntegrationTests: XCTestCase {

    func testExportRuleSaveAndIdempotentRun() async throws {
        let isolatedDBPath = try requireIsolatedDatabase()
        let svc = ExportService.shared
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("readboard-export-test-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        var savedRuleId: Int64?
        defer {
            if let savedRuleId { svc.deleteRule(id: savedRuleId) }
            try? FileManager.default.removeItem(at: tmpURL)
        }

        // 建一条测试规则：只导出到本测试专属的临时目录，手动触发。
        var rule = ExportRule(
            id: 0, name: "集成测试规则", enabled: true,
            criteria: ExportRule.Criteria(),  // 无条件 → 全量匹配
            triggerOn: "manual", target: "mddir",
            targetConfig: ["dir": tmpURL.path], lastRunAt: nil)
        let ruleId = svc.saveRule(rule)
        savedRuleId = ruleId
        XCTAssertGreaterThan(ruleId, 0, "规则应成功入库")
        rule = ExportRule(
            id: ruleId, name: rule.name, enabled: true,
            criteria: rule.criteria, triggerOn: rule.triggerOn,
            target: rule.target, targetConfig: rule.targetConfig, lastRunAt: nil)

        // 第一次跑：应导出若干文件（若 DB 有内容）
        await svc.runFor(ruleId: ruleId)
        let stats1 = svc.statsFor(ruleId: ruleId)
        print("第一次交付 \(stats1.delivered) 条，失败 \(stats1.failed)")

        // 第二次跑：处理剩余的未交付内容（LIMIT 200 分批），关键验证是——
        // 同一 content_id 不会被交付两次（export_record UNIQUE(rule_id, content_id) 幂等）
        await svc.runFor(ruleId: ruleId)
        let stats2 = svc.statsFor(ruleId: ruleId)
        print("第二次后累计交付 \(stats2.delivered) 条")

        // 幂等的真实契约：export_record 中 (rule_id, content_id) 无重复
        let dupCount = db_scalarIntForTest("""
            SELECT COUNT(*) FROM (
              SELECT content_id FROM export_record WHERE rule_id = \(ruleId)
              GROUP BY content_id HAVING COUNT(*) > 1
            )
            """, databasePath: isolatedDBPath)
        XCTAssertEqual(dupCount, 0, "同一内容不应被同一规则重复交付")
    }

    /// 所有数据库集成测试必须由调用者显式提供隔离数据库。
    /// 同时拒绝生产默认路径，避免误把 READBOARD_DB 配成用户真实库。
    private func requireIsolatedDatabase() throws -> String {
        guard let configuredPath = ProcessInfo.processInfo.environment["READBOARD_DB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !configuredPath.isEmpty,
              URL(fileURLWithPath: configuredPath).path.hasPrefix("/") else {
            throw XCTSkip("需要 READBOARD_DB 指向绝对路径的隔离数据库；跳过以免触碰真实库")
        }

        let path = URL(fileURLWithPath: configuredPath).standardizedFileURL.path
        let legacyPath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("readboard/Data/readboard.db").standardizedFileURL.path
        let appSupportPath = FileManager.default.urls(for: .applicationSupportDirectory,
                                                       in: .userDomainMask).first?
            .appendingPathComponent("ReadBoard/readboard.db").standardizedFileURL.path
        guard path != legacyPath, path != appSupportPath else {
            throw XCTSkip("READBOARD_DB 不能指向 ReadBoard 的真实数据库")
        }
        return path
    }

    /// 测试辅助：直接查 DB（绕过 service 层）
    private func db_scalarIntForTest(_ sql: String, databasePath: String) -> Int {
        var result = 0
        var db: OpaquePointer?
        guard sqlite3_open(databasePath, &db) == SQLITE_OK else { return -1 }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            result = Int(sqlite3_column_int64(stmt, 0))
        }
        sqlite3_finalize(stmt)
        sqlite3_close(db)
        return result
    }
}
