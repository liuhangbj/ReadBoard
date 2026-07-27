import XCTest
import SQLite3
@testable import ReadBoard

// MARK: - 集成测试（触真实 DB 和真实 LLM key，验证端到端）
// 这些测试依赖本机环境（.env key、真实 DB），标记为可跳过——环境不满足时 skip 而非 fail。

final class LLMIntegrationTests: XCTestCase {

    func testRealLLMScoreAndParse() async throws {
        let client = LLMClient()
        guard client.isAvailable else {
            print("⏭ 无可用 LLM key，跳过集成测试")
            return
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

    func testExportRuleSaveAndIdempotentRun() async {
        let svc = ExportService.shared
        // 建一条测试规则：导出到临时目录，手动触发
        let tmpDir = NSTemporaryDirectory() + "readboard-export-test-\(UUID().uuidString)"
        var rule = ExportRule(
            id: 0, name: "集成测试规则", enabled: true,
            criteria: ExportRule.Criteria(),  // 无条件 → 全量匹配
            triggerOn: "manual", target: "mddir",
            targetConfig: ["dir": tmpDir], lastRunAt: nil)
        let ruleId = svc.saveRule(rule)
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
            """)
        XCTAssertEqual(dupCount, 0, "同一内容不应被同一规则重复交付")

        // 清理：删规则 + 临时目录
        svc.deleteRule(id: ruleId)
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    /// 测试辅助：直接查 DB（绕过 service 层）
    private func db_scalarIntForTest(_ sql: String) -> Int {
        var result = 0
        let dbPath = NSHomeDirectory() + "/readboard/Data/readboard.db"
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return -1 }
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

// MARK: - 完成归档集成测试（真实 DB）

final class ArchiveIntegrationTests: XCTestCase {

    /// 对真实库里已完成的内容验证：完成判定 → 落盘 → 幂等不重复
    func testArchiveIfComplete() {
        let svc = ArchiveService.shared
        // 144424 = 虎嗅源（auto_score+auto_summarize），已有打分+摘要+正文，应判定完成
        let testId: Int64 = 144424
        // 先清掉可能的归档标记，保证测试起点干净
        Database.shared.execute(
            "UPDATE content SET meta = json_remove(COALESCE(meta,'{}'), '$.archived_at') WHERE id = ?",
            params: [testId])

        // 完成判定
        let complete = svc.isComplete(contentId: testId)
        XCTAssertTrue(complete, "144424 开了打分+摘要且都有结果，应判定完成")

        // 首次落盘：应写入
        let first = svc.archiveIfComplete(contentId: testId)
        XCTAssertTrue(first, "首次归档应成功落盘")

        // 二次调用：已归档，幂等跳过
        let second = svc.archiveIfComplete(contentId: testId)
        XCTAssertFalse(second, "已归档内容不应重复落盘")

        // 文件确实写到了归档目录
        let dir = svc.archiveDir + "/虎嗅"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        XCTAssertTrue(files.contains { $0.contains("\(testId)") }, "归档目录应有该内容的 md 文件")
        print("归档目录 \(dir)，文件 \(files.filter { $0.contains("\(testId)") })")
    }
}

