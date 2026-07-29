import XCTest
@testable import ReadBoard

final class PipelineWorkerConcurrencyTests: XCTestCase {
    private actor ActivityProbe {
        private var active = 0
        private var peak = 0

        func enter() {
            active += 1
            peak = max(peak, active)
        }

        func leave() {
            active -= 1
        }

        func peakValue() -> Int { peak }
    }

    func testLLMLaneHonorsConfiguredConcurrencyLimit() async {
        let scheduler = PipelineWorkScheduler(llmLimit: 2)
        let probe = ActivityProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try? await scheduler.run(in: .llm) {
                        await probe.enter()
                        try await Task.sleep(nanoseconds: 40_000_000)
                        await probe.leave()
                        return true
                    }
                }
            }
        }

        let peak = await probe.peakValue()
        XCTAssertEqual(peak, 2)
    }

    func testTranscriptionLaneIsAlwaysSerial() async {
        // 即使 LLM 通道配到最大值，Whisper 通道仍固定为 1。
        let scheduler = PipelineWorkScheduler(llmLimit: 4)
        let probe = ActivityProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = try? await scheduler.run(in: .transcription) {
                        await probe.enter()
                        try await Task.sleep(nanoseconds: 30_000_000)
                        await probe.leave()
                        return true
                    }
                }
            }
        }

        let peak = await probe.peakValue()
        XCTAssertEqual(peak, 1)
    }

    func testManualReprocessPlannerMergesContainedLLMStages() {
        let all = PipelinePolicy(
            autoScore: true, autoTranslate: true,
            autoTranscribe: false, autoSummarize: true)
        XCTAssertEqual(
            ManualReprocessPlanner.steps(policy: all, isMedia: false, isChineseMedia: false),
            [.translateFull],
            "翻译整合调用已经包含按需评分和摘要，不能再追加两次 LLM 请求")

        let scoreAndSummary = PipelinePolicy(
            autoScore: true, autoTranslate: false,
            autoTranscribe: false, autoSummarize: true)
        XCTAssertEqual(
            ManualReprocessPlanner.steps(
                policy: scoreAndSummary, isMedia: false, isChineseMedia: false),
            [.scoreWithSummary],
            "评分调用会同时写入摘要，不能再单独摘要")

        let summaryOnly = PipelinePolicy(autoSummarize: true)
        XCTAssertEqual(
            ManualReprocessPlanner.steps(
                policy: summaryOnly, isMedia: false, isChineseMedia: false),
            [.summarize])
    }

    func testManualReprocessPlannerKeepsMediaLanguageAndTranscriptionRules() {
        let all = PipelinePolicy(
            autoScore: true, autoTranslate: true,
            autoTranscribe: true, autoSummarize: true)
        XCTAssertEqual(
            ManualReprocessPlanner.steps(policy: all, isMedia: true, isChineseMedia: false),
            [.translateFull, .transcribe])
        XCTAssertEqual(
            ManualReprocessPlanner.steps(policy: all, isMedia: true, isChineseMedia: true),
            [.scoreWithSummary, .transcribe],
            "中文媒体跳过翻译，但仍保留评分/摘要和转录")

        let summaryAndTranscription = PipelinePolicy(
            autoTranscribe: true, autoSummarize: true)
        XCTAssertEqual(
            ManualReprocessPlanner.steps(
                policy: summaryAndTranscription, isMedia: true, isChineseMedia: true),
            [.transcribe],
            "转录管线会基于转录稿生成摘要，不应先对节目简介重复摘要")
    }

    @MainActor
    func testContentLockRejectsASecondManualOrWorkerOwner() {
        let contentId: Int64 = 9_990_001
        let worker = PipelineWorker.shared
        XCTAssertTrue(worker.tryLockContent(contentId))
        XCTAssertFalse(worker.tryLockContent(contentId))
        worker.unlockContent(contentId)
        XCTAssertTrue(worker.tryLockContent(contentId))
        worker.unlockContent(contentId)
    }

    @MainActor
    func testDerivedQueueRevalidatesChangedItemState() throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向临时数据库")
        }
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sourceId: Int64 = 9_995_001
        let contentId: Int64 = 9_995_011
        db.execute("DELETE FROM content WHERE id=?", params: [contentId])
        db.execute("DELETE FROM content_source WHERE id=?", params: [sourceId])
        defer {
            db.execute("DELETE FROM content WHERE id=?", params: [contentId])
            db.execute("DELETE FROM content_source WHERE id=?", params: [sourceId])
        }
        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id,stype,name,identifier,config,enabled)
            VALUES (?,'rss','dynamic-worker-test',?,'{}',1)
            """, params: [sourceId, "https://test.invalid/dynamic-worker-\(sourceId)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content
                (id,source_id,ctype,guid,source,title,url,content_md,fetch_status,auto_translate)
            VALUES (?,?,'article',?,'rss','动态剔除测试',?,'可翻译正文',2,1)
            """, params: [contentId, sourceId, "dynamic-worker-guid-\(contentId)",
                           "https://test.invalid/item/\(contentId)"]))

        let worker = PipelineWorker.shared
        XCTAssertEqual(worker.revalidatedTaskKindsForTesting(contentId: contentId), ["translate"])

        db.execute("UPDATE content SET auto_translate=0 WHERE id=?", params: [contentId])
        XCTAssertTrue(worker.revalidatedTaskKindsForTesting(contentId: contentId).isEmpty,
                      "排队后关闭条目开关，应在实际调用前自动剔除")

        db.execute("UPDATE content SET auto_translate=1,llm_translated_md='手动译文' WHERE id=?",
                   params: [contentId])
        XCTAssertTrue(worker.revalidatedTaskKindsForTesting(contentId: contentId).isEmpty,
                      "排队后结果已由其他入口生成，不得重复调用")

        db.execute("UPDATE content SET llm_translated_md=NULL WHERE id=?", params: [contentId])
        db.execute("UPDATE content_source SET enabled=0 WHERE id=?", params: [sourceId])
        XCTAssertTrue(worker.revalidatedTaskKindsForTesting(contentId: contentId).isEmpty,
                      "订阅源关闭后，已经装入内存的任务也必须失效")

        db.execute("UPDATE content_source SET enabled=1 WHERE id=?", params: [sourceId])
        db.execute("UPDATE content SET deleted_at=datetime('now') WHERE id=?",
                   params: [contentId])
        XCTAssertTrue(worker.revalidatedTaskKindsForTesting(contentId: contentId).isEmpty,
                      "软删除内容不得重新进入内容处理引擎")
    }

    @MainActor
    func testMediaPendingCountIncludesFetchStatusZeroAndExcludesDeletedRows() throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向临时数据库")
        }
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sourceId: Int64 = 9_996_001
        let validId: Int64 = 9_996_011
        let deletedId: Int64 = 9_996_012
        let duplicateId: Int64 = 9_996_013
        let ids = [validId, deletedId, duplicateId]
        db.execute("DELETE FROM content WHERE id IN (?,?,?)", params: ids)
        db.execute("DELETE FROM content_source WHERE id=?", params: [sourceId])
        let worker = PipelineWorker.shared
        let baseline = worker.refreshCountsForTesting()
        defer {
            db.execute("DELETE FROM content WHERE id IN (?,?,?)", params: ids)
            db.execute("DELETE FROM content_source WHERE id=?", params: [sourceId])
        }
        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id,stype,name,identifier,config,enabled)
            VALUES (?,'podcast','media-count-test',?,'{}',1)
            """, params: [sourceId, "https://test.invalid/media-count-\(sourceId)"]))
        for (id, deleted, duplicate) in [
            (validId, false, false), (deletedId, true, false), (duplicateId, false, true)
        ] {
            XCTAssertTrue(db.execute("""
                INSERT INTO content
                    (id,source_id,ctype,guid,source,title,url,excerpt,fetch_status,meta,
                     auto_transcribe,deleted_at,is_duplicate)
                VALUES (?,?,'podcast',?,'podcast','媒体计数测试',?,'节目简介',0,
                        '{"audio_url":"https://test.invalid/audio.mp3"}',1,?,?)
                """, params: [id, sourceId, "media-count-guid-\(id)",
                               "https://test.invalid/item/\(id)",
                               deleted ? "2026-07-29 00:00:00" : nil, duplicate ? 1 : 0]))
        }

        XCTAssertEqual(worker.pendingTaskIdsForTesting(
            ignoreWatermark: true, onlySourceId: sourceId), [validId])
        let after = worker.refreshCountsForTesting()
        XCTAssertEqual(after.transcribe, baseline.transcribe + 1,
                       "fetch_status=0 的播客必须计入转录，软删除和重复内容不能计入")
        XCTAssertEqual(after.unread, baseline.unread + 1,
                       "待处理计数应同时给出真实未读数")
        XCTAssertTrue(worker.pendingContentIds.contains(validId))
        XCTAssertFalse(worker.pendingContentIds.contains(deletedId))
        XCTAssertFalse(worker.pendingContentIds.contains(duplicateId))
    }

    @MainActor
    func testWorkerPlannerAssignsSummaryToScoreWithoutDuplicateCall() throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向临时数据库")
        }
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sourceId: Int64 = 9_997_001
        let contentId: Int64 = 9_997_011
        db.execute("DELETE FROM content WHERE id=?", params: [contentId])
        db.execute("DELETE FROM content_source WHERE id=?", params: [sourceId])
        defer {
            db.execute("DELETE FROM content WHERE id=?", params: [contentId])
            db.execute("DELETE FROM content_source WHERE id=?", params: [sourceId])
        }
        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id,stype,name,identifier,config,enabled)
            VALUES (?,'rss','merged-score-test',?,'{}',1)
            """, params: [sourceId, "https://test.invalid/merged-score-\(sourceId)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content
                (id,source_id,ctype,guid,source,title,url,content_md,fetch_status,
                 auto_score,auto_summarize)
            VALUES (?,?,'article',?,'rss','评分摘要合并测试',?,'完整正文',2,1,1)
            """, params: [contentId, sourceId, "merged-score-guid-\(contentId)",
                           "https://test.invalid/item/\(contentId)"]))

        XCTAssertEqual(PipelineWorker.shared.pendingTaskKindsForTesting(
            ignoreWatermark: true, onlySourceId: sourceId)[contentId], ["score"])
    }

    @MainActor
    func testHigherStageBackoffDoesNotFallThroughToDuplicateLowerStage() throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向临时数据库")
        }
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sourceId: Int64 = 9_997_101
        let contentId: Int64 = 9_997_111
        db.execute("DELETE FROM content_job WHERE content_id=?", params: [contentId])
        db.execute("DELETE FROM content WHERE id=?", params: [contentId])
        db.execute("DELETE FROM content_source WHERE id=?", params: [sourceId])
        defer {
            db.execute("DELETE FROM content_job WHERE content_id=?", params: [contentId])
            db.execute("DELETE FROM content WHERE id=?", params: [contentId])
            db.execute("DELETE FROM content_source WHERE id=?", params: [sourceId])
        }
        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id,stype,name,identifier,config,enabled)
            VALUES (?,'rss','stage-backoff-test',?,'{}',1)
            """, params: [sourceId, "https://test.invalid/stage-backoff-\(sourceId)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content
                (id,source_id,ctype,guid,source,title,url,content_md,fetch_status,
                 auto_translate,auto_score,auto_summarize)
            VALUES (?,?,'article',?,'rss','退避归属测试',?,'完整正文',2,1,1,1)
            """, params: [contentId, sourceId, "stage-backoff-guid-\(contentId)",
                           "https://test.invalid/item/\(contentId)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content_job (content_id,jtype,status,finished_at)
            VALUES (?,'translate',3,datetime('now'))
            """, params: [contentId]))

        let kinds = PipelineWorker.shared.pendingTaskKindsForTesting(
            ignoreWatermark: true, onlySourceId: sourceId)
        XCTAssertNil(kinds[contentId],
                     "翻译处于退避时不能退化成单独评分或摘要，避免重复提交正文")
    }

    @MainActor
    func testNewestFirstKeepsAnOldestTaskQuota() throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向临时数据库")
        }
        let db = Database.shared
        XCTAssertTrue(db.open())
        let worker = PipelineWorker.shared
        let sourceId: Int64 = 9_998_001
        let firstId: Int64 = 9_998_100
        let itemCount = 105
        db.execute("DELETE FROM content WHERE id BETWEEN ? AND ?",
                   params: [firstId, firstId + Int64(itemCount - 1)])
        db.execute("DELETE FROM content_source WHERE id=?", params: [sourceId])
        let oldLimit = worker.batchLimit
        worker.batchLimit = 100
        defer {
            worker.batchLimit = oldLimit
            db.execute("DELETE FROM content WHERE id BETWEEN ? AND ?",
                       params: [firstId, firstId + Int64(itemCount - 1)])
            db.execute("DELETE FROM content_source WHERE id=?", params: [sourceId])
        }
        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id,stype,name,identifier,config,enabled)
            VALUES (?,'rss','newest-order-test',?,'{}',1)
            """, params: [sourceId, "https://test.invalid/newest-order-\(sourceId)"]))
        XCTAssertTrue(db.transaction {
            for offset in 0..<itemCount {
                let id = firstId + Int64(offset)
                guard db.execute("""
                    INSERT INTO content
                        (id,source_id,ctype,guid,source,title,url,content_md,fetch_status,auto_translate)
                    VALUES (?,?,'article',?,'rss','顺序测试',?,'正文',2,1)
                    """, params: [id, sourceId, "newest-order-guid-\(id)",
                                   "https://test.invalid/item/\(id)"]) else { return false }
            }
            return true
        })

        let ids = worker.pendingTaskIdsForTesting(ignoreWatermark: true, onlySourceId: sourceId)
        XCTAssertEqual(ids.count, 100)
        XCTAssertEqual(Array(ids.prefix(3)), [firstId + 104, firstId + 103, firstId + 102])
        XCTAssertEqual(Array(ids.suffix(3)), [firstId + 17, firstId + 18, firstId + 19],
                       "每批应保留20个最旧任务名额，避免旧内容永久饥饿")
    }
}
