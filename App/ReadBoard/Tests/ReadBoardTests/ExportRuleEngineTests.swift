import XCTest
@testable import ReadBoard

final class ExportRuleEngineTests: XCTestCase {
    private let db = Database.shared
    private let service = ExportService.shared

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向临时数据库；跳过以免触碰真实库")
        }
        XCTAssertTrue(db.open())
    }

    func testV24SchemaAndRuleOptionsRoundTrip() throws {
        XCTAssertEqual(db.scalarInt("PRAGMA user_version;"), 25)
        let ruleColumns = Set(db.queryRows("PRAGMA table_info(export_rule);").compactMap { $0["name"] })
        for column in ["revision", "artifact", "missing_policy", "output_format",
                       "subfolder_template", "filename_template", "write_policy",
                       "history_scope", "frontmatter_fields", "attachments_policy"] {
            XCTAssertTrue(ruleColumns.contains(column), "export_rule 缺少 \(column)")
        }
        let recordColumns = Set(db.queryRows("PRAGMA table_info(export_record);").compactMap { $0["name"] })
        for column in ["artifact", "revision", "rendered_hash", "attempts", "updated_at"] {
            XCTAssertTrue(recordColumns.contains(column), "export_record 缺少 \(column)")
        }

        var rule = makeRule(name: "roundtrip")
        rule.triggerOn = "ready"
        rule.artifact = "summary_translated"
        rule.missingPolicy = "fallback_original"
        rule.subfolderTemplate = "ReadBoard/{source}/{year}/{month}"
        rule.titleTemplate = "{date:yyyy-MM-dd} {title}-{id}"
        rule.writePolicy = "versioned"
        rule.overwrite = false
        rule.historyScope = "all"
        rule.frontmatterFields = ["id", "title", "url", "artifact"]
        let id = service.saveRule(rule)
        defer { service.deleteRule(id: id) }

        let loaded = try XCTUnwrap(service.listRules().first { $0.id == id })
        XCTAssertEqual(loaded.triggerOn, "ready")
        XCTAssertEqual(loaded.artifact, "summary_translated")
        XCTAssertEqual(loaded.missingPolicy, "fallback_original")
        XCTAssertEqual(loaded.subfolderTemplate, "ReadBoard/{source}/{year}/{month}")
        XCTAssertEqual(loaded.titleTemplate, "{date:yyyy-MM-dd} {title}-{id}")
        XCTAssertEqual(loaded.writePolicy, "versioned")
        XCTAssertEqual(loaded.historyScope, "all")
        XCTAssertEqual(loaded.frontmatterFields, ["id", "title", "url", "artifact"])
    }

    func testObsidianUsesVaultTemplateFrontmatterAndRejectsEscape() async throws {
        let contentId: Int64 = 9_710_001
        db.execute("DELETE FROM content WHERE id=?", params: [contentId])
        defer { db.execute("DELETE FROM content WHERE id=?", params: [contentId]) }
        XCTAssertTrue(db.execute("""
            INSERT INTO content
                (id, ctype, guid, source, title, url, author, content_md, llm_summary,
                 llm_translated_md, published_at, language)
            VALUES (?, 'article', ?, 'rss', '安全/路径测试', ?, '作者', '# 原文',
                    '测试摘要', '# 译文', '2026-07-29 08:00:00', 'zh-cn')
            """, params: [contentId, "export-engine-\(contentId)",
                           "https://test.invalid/\(contentId)"]))

        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("readboard-vault-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        var rule = makeRule(name: "obsidian")
        rule.target = "obsidian"
        rule.targetConfig = ["dir": vault.path]
        rule.artifact = "summary_translated"
        rule.subfolderTemplate = "ReadBoard/{source}/{year}/{month}"
        rule.titleTemplate = "{date:yyyy-MM-dd} {title}-{id}"
        rule.frontmatterFields = ["id", "title", "url", "artifact", "summary"]

        let preview = service.preview(rule: rule, maxSamples: 1)
        XCTAssertEqual(preview.matchingCount, 1)
        let sample = try XCTUnwrap(preview.samples.first)
        XCTAssertTrue(sample.destination?.hasPrefix(vault.path + "/") == true)
        XCTAssertTrue(sample.markdown?.contains("## 摘要") == true)

        let result = await service.deliverSingle(rule: rule, contentId: contentId)
        XCTAssertTrue(result.0, result.2 ?? "导出失败")
        let path = try XCTUnwrap(result.1)
        XCTAssertTrue(path.hasPrefix(vault.path + "/ReadBoard/rss/2026/07/"))
        let markdown = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(markdown.contains("readboard_id: \(contentId)"))
        XCTAssertTrue(markdown.contains("artifact_type: \"summary_translated\""))
        XCTAssertFalse(markdown.contains("content_type:"))

        rule.subfolderTemplate = "../escape"
        let escaped = await service.deliverSingle(rule: rule, contentId: contentId)
        XCTAssertFalse(escaped.0)
        XCTAssertTrue(escaped.2?.contains("不安全") == true)
    }

    func testRevisionCreatesNewDeliveryAndSameHashIsIdempotent() async throws {
        let contentId: Int64 = 9_720_001
        db.execute("DELETE FROM content WHERE id=?", params: [contentId])
        XCTAssertTrue(db.execute("""
            INSERT INTO content (id, ctype, guid, source, title, url, content_md)
            VALUES (?, 'article', ?, 'rss', '修订测试', ?, '# 正文')
            """, params: [contentId, "export-revision-\(contentId)",
                           "https://test.invalid/\(contentId)"]))
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("readboard-revision-\(UUID().uuidString)", isDirectory: true)
        var rule = makeRule(name: "revision")
        rule.targetConfig = ["dir": vault.path]
        rule.historyScope = "all"
        let ruleId = service.saveRule(rule)
        defer {
            service.deleteRule(id: ruleId)
            db.execute("DELETE FROM content WHERE id=?", params: [contentId])
            try? FileManager.default.removeItem(at: vault)
        }

        await service.runFor(ruleId: ruleId)
        await service.runFor(ruleId: ruleId)
        XCTAssertEqual(db.scalarInt("SELECT COUNT(*) FROM export_record WHERE rule_id=?",
                                    params: [ruleId]), 1)
        XCTAssertEqual(db.scalarInt("SELECT attempts FROM export_record WHERE rule_id=?",
                                    params: [ruleId]), 1)
        XCTAssertFalse((db.scalarString("SELECT rendered_hash FROM export_record WHERE rule_id=?",
                                        params: [ruleId]) ?? "").isEmpty)

        var edited = try XCTUnwrap(service.listRules().first { $0.id == ruleId })
        edited.titleTemplate = "v2-{title}-{id}"
        _ = service.saveRule(edited)
        let revised = try XCTUnwrap(service.listRules().first { $0.id == ruleId })
        XCTAssertEqual(revised.revision, 2)
        await service.runFor(ruleId: ruleId)
        XCTAssertEqual(db.scalarInt("SELECT COUNT(*) FROM export_record WHERE rule_id=?",
                                    params: [ruleId]), 2)
    }

    func testScheduledFrequencyUsesLastRunTime() throws {
        var rule = makeRule(name: "schedule")
        rule.lastRunAt = "2026-07-29 00:00:00"
        rule.targetConfig["schedule_interval"] = "hourly"

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        XCTAssertFalse(service.scheduledRuleIsDueForTesting(
            rule, now: try XCTUnwrap(formatter.date(from: "2026-07-29 00:59:59"))))
        XCTAssertTrue(service.scheduledRuleIsDueForTesting(
            rule, now: try XCTUnwrap(formatter.date(from: "2026-07-29 01:00:00"))))

        rule.targetConfig["schedule_interval"] = "weekly"
        XCTAssertFalse(service.scheduledRuleIsDueForTesting(
            rule, now: try XCTUnwrap(formatter.date(from: "2026-08-04 23:59:59"))))
        XCTAssertTrue(service.scheduledRuleIsDueForTesting(
            rule, now: try XCTUnwrap(formatter.date(from: "2026-08-05 00:00:00"))))
    }

    private func makeRule(name: String) -> ExportRule {
        var rule = ExportRule(id: 0, name: name, enabled: true,
                              criteria: ExportRule.Criteria(), triggerOn: "manual",
                              target: "mddir", targetConfig: [:], lastRunAt: nil)
        rule.historyScope = "all"
        return rule
    }
}
