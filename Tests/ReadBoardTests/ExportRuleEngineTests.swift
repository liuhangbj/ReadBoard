import XCTest
import Foundation
@testable import ReadBoard

private final class WebhookURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { return nil }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

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
        XCTAssertEqual(db.scalarInt("PRAGMA user_version;"), 35)
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
        let queueColumns = Set(db.queryRows("PRAGMA table_info(export_ready_queue);").compactMap { $0["name"] })
        for column in ["content_id", "generation", "attempts", "available_at", "last_error"] {
            XCTAssertTrue(queueColumns.contains(column), "export_ready_queue 缺少 \(column)")
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

    func testInboxExportIsOptInButManualOverrideRemainsPossible() throws {
        let contentID: Int64 = 9_710_099
        defer { db.execute("DELETE FROM content WHERE id=?", params: [contentID]) }
        XCTAssertTrue(db.execute("""
            INSERT INTO content
                (id, ctype, guid, source, title, url, content_md,
                 visibility_state, ingest_origin, meta)
            VALUES (?, 'article', ?, 'web', '收件箱导出测试', ?, '# 正文',
                    'visible', 'inbox', '{"inbox_allow_export":"false"}')
            """, params: [contentID, "inbox-export-\(contentID)",
                           "https://example.com/inbox-export-\(contentID)"]))
        let rule = makeRule(name: "inbox-export")
        XCTAssertFalse(service.preview(rule: rule, maxSamples: 10)
            .samples.contains(where: { $0.contentId == contentID }))
        XCTAssertTrue(db.execute("""
            UPDATE content SET meta=json_set(meta,'$.inbox_allow_export','true') WHERE id=?
            """, params: [contentID]))
        XCTAssertTrue(service.preview(rule: rule, maxSamples: 100)
            .samples.contains(where: { $0.contentId == contentID }))
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
        let platform = ExportPlatformConfig.shared
        let oldEnabled = platform.isEnabled("obsidian")
        let oldDirectory = platform.obsidianDir
        platform.setEnabled("obsidian", true)
        platform.obsidianDir = vault.path
        defer {
            platform.setEnabled("obsidian", oldEnabled)
            platform.obsidianDir = oldDirectory
            try? FileManager.default.removeItem(at: vault)
        }

        var rule = makeRule(name: "obsidian")
        rule.target = "obsidian"
        rule.targetConfig = [:]
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

    func testWebhookPostsJSONWithConfiguredHeaders() async throws {
        let token = UUID().uuidString
        let contentId: Int64 = 9_715_001
        db.execute("DELETE FROM content WHERE id=?", params: [contentId])
        XCTAssertTrue(db.execute("""
            INSERT INTO content (id, ctype, guid, source, title, url, content_md, llm_summary)
            VALUES (?, 'article', ?, 'rss', ?, ?, '# Webhook 正文', 'Webhook 摘要')
            """, params: [contentId, "webhook-\(token)", "Webhook \(token)",
                           "https://test.invalid/webhook/\(token)"]))

        let platform = ExportPlatformConfig.shared
        let oldEnabled = platform.isEnabled("webhook")
        let oldURL = platform.webhookURL
        let oldHeaders = platform.webhookHeaders
        let endpoint = "https://webhook.test.invalid/receive"
        platform.setEnabled("webhook", true)
        platform.webhookURL = endpoint
        platform.webhookHeaders = ["Authorization": "Bearer test-token", "X-ReadBoard": "test"]

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [WebhookURLProtocolStub.self]
        let session = URLSession(configuration: sessionConfiguration)
        service.setWebhookSessionForTesting(session)
        var receivedRequest: URLRequest?
        var receivedBody: Data?
        WebhookURLProtocolStub.handler = { request in
            receivedRequest = request
            receivedBody = requestBodyData(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 204,
                httpVersion: "HTTP/1.1", headerFields: nil))
            return (response, Data())
        }

        var rule = makeRule(name: "webhook")
        rule.target = "webhook"
        rule.criteria.keywords = [token]
        let ruleId = service.saveRule(rule)
        defer {
            service.deleteRule(id: ruleId)
            db.execute("DELETE FROM content WHERE id=?", params: [contentId])
            WebhookURLProtocolStub.handler = nil
            service.setWebhookSessionForTesting(nil)
            session.invalidateAndCancel()
            platform.setEnabled("webhook", oldEnabled)
            platform.webhookURL = oldURL
            platform.webhookHeaders = oldHeaders
        }

        await service.runFor(ruleId: ruleId)

        let request = try XCTUnwrap(receivedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-ReadBoard"), "test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        let body = try XCTUnwrap(receivedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["event"] as? String, "readboard.export")
        XCTAssertEqual(json["artifact"] as? String, "original")
        let markdown = try XCTUnwrap(json["markdown"] as? String)
        XCTAssertTrue(markdown.contains("id: \(contentId)"))
        XCTAssertTrue(markdown.contains("# Webhook \(token)"))
        XCTAssertTrue(markdown.contains("# Webhook 正文"))
        XCTAssertEqual(((json["content"] as? [String: Any])?["id"] as? NSNumber)?.int64Value,
                       contentId)
        XCTAssertEqual(db.scalarInt("""
            SELECT COUNT(*) FROM export_record
            WHERE rule_id=? AND status='delivered' AND destination=?
            """, params: [ruleId, endpoint]), 1)
    }

    func testDisabledWebhookRuleDoesNotExecute() async throws {
        let token = UUID().uuidString
        let contentId: Int64 = 9_716_001
        db.execute("DELETE FROM content WHERE id=?", params: [contentId])
        XCTAssertTrue(db.execute("""
            INSERT INTO content (id, ctype, guid, source, title, url, content_md)
            VALUES (?, 'article', ?, 'rss', ?, ?, '# 正文')
            """, params: [contentId, "disabled-webhook-\(token)", "Disabled \(token)",
                           "https://test.invalid/disabled-webhook/\(token)"]))

        let platform = ExportPlatformConfig.shared
        let oldEnabled = platform.isEnabled("webhook")
        platform.setEnabled("webhook", false)
        var rule = makeRule(name: "disabled-webhook")
        rule.target = "webhook"
        rule.criteria.keywords = [token]
        let ruleId = service.saveRule(rule)
        defer {
            service.deleteRule(id: ruleId)
            db.execute("DELETE FROM content WHERE id=?", params: [contentId])
            platform.setEnabled("webhook", oldEnabled)
        }

        await service.runFor(ruleId: ruleId)

        XCTAssertEqual(db.scalarInt("SELECT COUNT(*) FROM export_record WHERE rule_id=?",
                                    params: [ruleId]), 0)
        XCTAssertNil(db.scalarString("SELECT last_run_at FROM export_rule WHERE id=?",
                                     params: [ruleId]))
    }

    func testReadyQueueRetainsDisabledPlatformUntilItCanDeliver() async throws {
        let token = UUID().uuidString
        let contentId: Int64 = 9_716_101
        db.execute("DELETE FROM content WHERE id=?", params: [contentId])
        XCTAssertTrue(db.execute("""
            INSERT INTO content (id, ctype, guid, source, title, url, content_md)
            VALUES (?, 'article', ?, 'rss', ?, ?, '# 正文')
            """, params: [contentId, "ready-retry-\(token)", "Ready Retry \(token)",
                           "https://test.invalid/ready-retry/\(token)"]))

        let platform = ExportPlatformConfig.shared
        let oldEnabled = platform.isEnabled("webhook")
        let oldURL = platform.webhookURL
        let boardWasEnabled = FeatureBoard.export.enabled
        FeatureBoard.setEnabled(.export, true)
        platform.setEnabled("webhook", false)
        platform.webhookURL = "https://webhook.test.invalid/ready-retry"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebhookURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        service.setWebhookSessionForTesting(session)
        WebhookURLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 204,
                httpVersion: "HTTP/1.1", headerFields: nil))
            return (response, Data())
        }

        var rule = makeRule(name: "ready-retry")
        rule.triggerOn = "ready"
        rule.target = "webhook"
        rule.criteria.keywords = [token]
        let ruleId = service.saveRule(rule)
        defer {
            service.deleteRule(id: ruleId)
            db.execute("DELETE FROM content WHERE id=?", params: [contentId])
            WebhookURLProtocolStub.handler = nil
            service.setWebhookSessionForTesting(nil)
            session.invalidateAndCancel()
            FeatureBoard.setEnabled(.export, boardWasEnabled)
            platform.setEnabled("webhook", oldEnabled)
            platform.webhookURL = oldURL
        }

        await service.runPending(trigger: "ready", contentId: contentId)
        XCTAssertEqual(service.queuedReadyCountForTesting(contentId: contentId), 1)
        XCTAssertEqual(db.scalarInt(
            "SELECT attempts FROM export_ready_queue WHERE content_id=?",
            params: [contentId]), 1)
        XCTAssertEqual(db.scalarInt(
            "SELECT COUNT(*) FROM export_record WHERE rule_id=?", params: [ruleId]), 0)

        platform.setEnabled("webhook", true)
        await service.runPending(trigger: "ready", contentId: contentId)
        XCTAssertEqual(service.queuedReadyCountForTesting(contentId: contentId), 0)
        XCTAssertEqual(db.scalarInt("""
            SELECT COUNT(*) FROM export_record
            WHERE rule_id=? AND content_id=? AND status='delivered'
            """, params: [ruleId, contentId]), 1)
    }

    func testConcurrentReadyTriggersAreQueuedInsteadOfDropped() async throws {
        let token = UUID().uuidString
        let contentIds: [Int64] = [9_719_001, 9_719_002]
        for contentId in contentIds {
            db.execute("DELETE FROM content WHERE id=?", params: [contentId])
            XCTAssertTrue(db.execute("""
                INSERT INTO content (id, ctype, guid, source, title, url, content_md)
                VALUES (?, 'article', ?, 'rss', ?, ?, '# 正文')
                """, params: [contentId, "queued-ready-\(token)-\(contentId)",
                                "Queued Ready \(token) \(contentId)",
                                "https://test.invalid/queued-ready/\(contentId)"]))
        }

        let platform = ExportPlatformConfig.shared
        let oldEnabled = platform.isEnabled("webhook")
        let oldURL = platform.webhookURL
        platform.setEnabled("webhook", true)
        platform.webhookURL = "https://webhook.test.invalid/queued-ready"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebhookURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        service.setWebhookSessionForTesting(session)
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        WebhookURLProtocolStub.handler = { request in
            if let body = requestBodyData(request),
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let content = json["content"] as? [String: Any],
               (content["id"] as? NSNumber)?.int64Value == contentIds[0] {
                firstEntered.signal()
                _ = releaseFirst.wait(timeout: .now() + 5)
            }
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 204,
                httpVersion: "HTTP/1.1", headerFields: nil))
            return (response, Data())
        }

        var rule = makeRule(name: "queued-ready")
        rule.triggerOn = "ready"
        rule.target = "webhook"
        rule.criteria.keywords = [token]
        let ruleId = service.saveRule(rule)
        defer {
            releaseFirst.signal()
            service.deleteRule(id: ruleId)
            for contentId in contentIds {
                db.execute("DELETE FROM content WHERE id=?", params: [contentId])
            }
            WebhookURLProtocolStub.handler = nil
            service.setWebhookSessionForTesting(nil)
            session.invalidateAndCancel()
            platform.setEnabled("webhook", oldEnabled)
            platform.webhookURL = oldURL
        }

        let exportService = service
        let firstContentID = contentIds[0]
        let secondContentID = contentIds[1]
        let first = Task {
            await exportService.runPending(trigger: "ready", contentId: firstContentID)
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)
        let second = Task {
            await exportService.runPending(trigger: "ready", contentId: secondContentID)
        }
        try await Task.sleep(for: .milliseconds(100))
        releaseFirst.signal()
        await first.value
        await second.value

        XCTAssertEqual(db.scalarInt("""
            SELECT COUNT(DISTINCT content_id) FROM export_record
            WHERE rule_id=? AND status='delivered'
            """, params: [ruleId]), 2)
    }

    func testReadyQueueReexportsAfterContentChanges() async throws {
        let contentId: Int64 = 9_719_101
        db.execute("DELETE FROM content WHERE id=?", params: [contentId])
        XCTAssertTrue(db.execute("""
            INSERT INTO content (id, ctype, guid, source, title, url, content_md)
            VALUES (?, 'article', ?, 'rss', 'ready 覆盖测试', ?, '# 第一版')
            """, params: [contentId, "ready-reexport-\(contentId)",
                           "https://test.invalid/ready-reexport/\(contentId)"]))

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("readboard-ready-\(UUID().uuidString)", isDirectory: true)
        var rule = makeRule(name: "ready-reexport")
        rule.triggerOn = "ready"
        rule.targetConfig = ["dir": output.path]
        rule.titleTemplate = "ready-{id}"
        rule.writePolicy = "overwrite"
        let ruleId = service.saveRule(rule)
        let boardWasEnabled = FeatureBoard.export.enabled
        FeatureBoard.setEnabled(.export, true)
        defer {
            FeatureBoard.setEnabled(.export, boardWasEnabled)
            service.deleteRule(id: ruleId)
            db.execute("DELETE FROM content WHERE id=?", params: [contentId])
            try? FileManager.default.removeItem(at: output)
        }

        await service.runPending(trigger: "ready", contentId: contentId)
        XCTAssertEqual(service.queuedReadyCountForTesting(contentId: contentId), 0)
        let firstHash = try XCTUnwrap(db.scalarString("""
            SELECT rendered_hash FROM export_record
            WHERE rule_id=? AND content_id=? AND revision=1
            """, params: [ruleId, contentId]))

        XCTAssertTrue(db.execute(
            "UPDATE content SET content_md='# 第二版' WHERE id=?", params: [contentId]))
        XCTAssertEqual(service.queuedReadyCountForTesting(contentId: contentId), 1)
        XCTAssertEqual(db.scalarInt(
            "SELECT generation FROM export_ready_queue WHERE content_id=?",
            params: [contentId]), 1)

        // 模拟 Worker 尚未消费时又完成一项处理；同一篇合并为更高 generation。
        XCTAssertTrue(db.execute(
            "UPDATE content SET llm_summary='新摘要' WHERE id=?", params: [contentId]))
        XCTAssertEqual(db.scalarInt(
            "SELECT generation FROM export_ready_queue WHERE content_id=?",
            params: [contentId]), 2)

        await service.drainReadyQueueForTesting()
        XCTAssertEqual(service.queuedReadyCountForTesting(contentId: contentId), 0)
        let record = try XCTUnwrap(db.queryRows("""
            SELECT destination, rendered_hash, attempts FROM export_record
            WHERE rule_id=? AND content_id=? AND revision=1
            """, params: [ruleId, contentId]).first)
        XCTAssertNotEqual(record["rendered_hash"], firstHash)
        XCTAssertEqual(record["attempts"], "2")
        let destination = try XCTUnwrap(record["destination"])
        XCTAssertTrue(try String(contentsOfFile: destination, encoding: .utf8).contains("# 第二版"))
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

    func testRuleStatsCountDistinctContentAcrossRevisions() throws {
        let contentIds: [Int64] = [9_721_001, 9_721_002]
        for id in contentIds { db.execute("DELETE FROM content WHERE id=?", params: [id]) }
        for id in contentIds {
            XCTAssertTrue(db.execute("""
                INSERT INTO content (id, ctype, guid, source, title, url, content_md)
                VALUES (?, 'article', ?, 'rss', '统计去重测试', ?, '# 正文')
                """, params: [id, "export-stats-\(id)", "https://test.invalid/\(id)"]))
        }
        let ruleId = service.saveRule(makeRule(name: "stats-distinct"))
        defer {
            service.deleteRule(id: ruleId)
            for id in contentIds { db.execute("DELETE FROM content WHERE id=?", params: [id]) }
        }

        XCTAssertTrue(db.execute("""
            INSERT INTO export_record
                (rule_id,content_id,artifact,revision,status,attempts,updated_at)
            VALUES (?,?,'original',1,'delivered',1,datetime('now')),
                   (?,?,'original',2,'delivered',1,datetime('now')),
                   (?,?,'original',1,'delivered',1,datetime('now')),
                   (?,?,'translated',1,'failed',1,datetime('now')),
                   (?,?,'translated',2,'failed',1,datetime('now'));
            """, params: [ruleId, contentIds[0], ruleId, contentIds[0],
                            ruleId, contentIds[1], ruleId, contentIds[0],
                            ruleId, contentIds[0]]))

        let stats = service.statsFor(ruleId: ruleId)
        XCTAssertEqual(stats.delivered, 2)
        XCTAssertEqual(stats.failed, 1)
    }

    func testFullHistoryExportContinuesPastTwoThousandItems() async throws {
        let token = UUID().uuidString
        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (stype, name, identifier)
            VALUES ('rss', '批量导出测试', ?)
            """, params: ["export-batch-\(token)"]))
        let sourceId = db.lastInsertId()
        XCTAssertGreaterThan(sourceId, 0)

        let itemCount = 2_005
        XCTAssertTrue(db.transaction {
            for index in 0..<itemCount {
                guard db.execute("""
                    INSERT INTO content (source_id, ctype, guid, source, title, url, content_md)
                    VALUES (?, 'article', ?, 'rss', ?, ?, '# 正文')
                    """, params: [sourceId, "export-batch-\(token)-\(index)",
                                   "批量导出 \(index)",
                                   "https://test.invalid/export-batch/\(token)/\(index)"]) else {
                    return false
                }
            }
            return true
        })

        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("readboard-batch-\(token)", isDirectory: true)
        var rule = makeRule(name: "full-history-over-2000")
        rule.criteria.sourceIds = [sourceId]
        rule.targetConfig = ["dir": vault.path]
        rule.titleTemplate = "batch"
        rule.writePolicy = "skip"
        rule.frontmatterFields = []
        let ruleId = service.saveRule(rule)
        defer {
            service.deleteRule(id: ruleId)
            db.execute("DELETE FROM content WHERE source_id=?", params: [sourceId])
            db.execute("DELETE FROM content_source WHERE id=?", params: [sourceId])
            try? FileManager.default.removeItem(at: vault)
        }

        await service.runFor(ruleId: ruleId)

        XCTAssertEqual(db.scalarInt("""
            SELECT COUNT(*) FROM export_record
            WHERE rule_id=? AND status='delivered'
            """, params: [ruleId]), itemCount)
    }

    func testPublishedEndDateIncludesWholeDayAcrossTimestampFormats() throws {
        let token = UUID().uuidString
        let firstId: Int64 = 9_717_001
        let rows: [(Int64, String)] = [
            (firstId, "2026-07-28T23:59:59Z"),
            (firstId + 1, "2026-07-29T08:00:00Z"),
            (firstId + 2, "2026-07-29 22:30:00"),
            (firstId + 3, "2026-07-30T00:00:00Z")
        ]
        defer {
            db.execute("DELETE FROM content WHERE id BETWEEN ? AND ?",
                       params: [firstId, firstId + Int64(rows.count - 1)])
        }
        XCTAssertTrue(db.transaction {
            for (id, publishedAt) in rows {
                guard db.execute("""
                    INSERT INTO content
                        (id, ctype, guid, source, title, url, content_md, published_at)
                    VALUES (?, 'article', ?, 'rss', ?, ?, '# 正文', ?)
                    """, params: [id, "published-range-\(token)-\(id)", "日期测试 \(token)",
                                   "https://test.invalid/published-range/\(token)/\(id)", publishedAt]) else {
                    return false
                }
            }
            return true
        })

        var rule = makeRule(name: "published-end-date")
        rule.criteria.keywords = [token]
        rule.criteria.publishedAfter = "2026-07-29"
        rule.criteria.publishedBefore = "2026-07-29 23:59:59" // 兼容已经保存的旧规则
        XCTAssertEqual(service.preview(rule: rule, maxSamples: 0).matchingCount, 2)

        rule.criteria.publishedBefore = "2026-07-29" // 新版界面保存格式
        XCTAssertEqual(service.preview(rule: rule, maxSamples: 0).matchingCount, 2)
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
