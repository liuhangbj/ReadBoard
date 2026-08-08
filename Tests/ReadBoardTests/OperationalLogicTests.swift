import XCTest
@testable import ReadBoard

final class FailedJobServiceTests: XCTestCase {
    func testRecentFailuresOnlyShowsLatestStatePerContentAndType() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sourceId: Int64 = 9_500_010
        let recoveredId: Int64 = 9_500_011
        let failingId: Int64 = 9_500_012
        cleanup(ids: [recoveredId, failingId])
        db.execute("DELETE FROM content_source WHERE id = ?", params: [sourceId])
        defer {
            cleanup(ids: [recoveredId, failingId])
            db.execute("DELETE FROM content_source WHERE id = ?", params: [sourceId])
        }

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id, stype, name, identifier, enabled, config)
            VALUES (?, 'rss', '最近失败测试', ?, 1, '{}');
            """, params: [sourceId, "https://test.invalid/recent-failure-\(sourceId)"]))

        for id in [recoveredId, failingId] {
            XCTAssertTrue(db.execute("""
                INSERT INTO content (id, guid, source_id, ctype, source, title, url, fetch_status)
                VALUES (?, ?, ?, 'article', 'rss', ?, ?, 2);
                """, params: [id, "failed-job-guid-\(id)", sourceId, "失败任务测试 \(id)",
                                "https://test.invalid/item/\(id)"]))
        }
        XCTAssertTrue(db.execute(
            "UPDATE content SET auto_score=1, auto_translate=1 WHERE id IN (?, ?)",
            params: [recoveredId, failingId]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content_job (content_id, jtype, status, finished_at, error)
            VALUES (?, 'score', 3, datetime('now', '-2 minutes'), '旧失败'),
                   (?, 'score', 2, datetime('now', '-1 minute'), NULL),
                   (?, 'translate', 3, datetime('now'), '最新仍失败');
            """, params: [recoveredId, recoveredId, failingId]))

        let failures = FailedJobService.shared.recentFailures(limit: 100)
        XCTAssertFalse(failures.contains { $0.contentId == recoveredId && $0.jtype == "score" })
        XCTAssertTrue(failures.contains { $0.contentId == failingId && $0.jtype == "translate" })
    }

    func testPausedFailuresExposeSourceTitleAndConsecutiveFailureCount() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sourceId: Int64 = 9_500_020
        let pausedId: Int64 = 9_500_021
        let recoveredId: Int64 = 9_500_022
        cleanup(ids: [pausedId, recoveredId])
        db.execute("DELETE FROM content_source WHERE id = ?", params: [sourceId])
        defer {
            cleanup(ids: [pausedId, recoveredId])
            db.execute("DELETE FROM content_source WHERE id = ?", params: [sourceId])
        }

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id, stype, name, identifier, enabled, config)
            VALUES (?, 'rss', '失败来源测试', 'https://test.invalid/feed', 1, '{}');
            """, params: [sourceId]))
        for id in [pausedId, recoveredId] {
            XCTAssertTrue(db.execute("""
                INSERT INTO content (id, guid, source_id, ctype, source, title, url, fetch_status)
                VALUES (?, ?, ?, 'article', 'rss', ?, ?, 2);
                """, params: [id, "paused-failure-guid-\(id)", sourceId,
                                "暂停任务测试 \(id)", "https://test.invalid/item/\(id)"]))
        }
        XCTAssertTrue(db.execute(
            "UPDATE content SET auto_translate=1, auto_score=1 WHERE id IN (?, ?)",
            params: [pausedId, recoveredId]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content_job (content_id, jtype, status, finished_at, error)
            VALUES
              (?, 'translate', 3, datetime('now', '-3 minutes'), '第一次失败'),
              (?, 'translate', 3, datetime('now', '-2 minutes'), '第二次失败'),
              (?, 'translate', 3, datetime('now', '-1 minute'), '最新失败'),
              (?, 'score', 3, datetime('now', '-4 minutes'), '旧失败一'),
              (?, 'score', 3, datetime('now', '-3 minutes'), '旧失败二'),
              (?, 'score', 3, datetime('now', '-2 minutes'), '旧失败三'),
              (?, 'score', 2, datetime('now', '-1 minute'), NULL);
            """, params: [pausedId, pausedId, pausedId,
                            recoveredId, recoveredId, recoveredId, recoveredId]))

        let failures = FailedJobService.shared.pausedFailures()
        let paused = try XCTUnwrap(failures.first {
            $0.contentId == pausedId && $0.jtype == "translate"
        })
        XCTAssertEqual(paused.title, "暂停任务测试 \(pausedId)")
        XCTAssertEqual(paused.sourceName, "失败来源测试")
        XCTAssertEqual(paused.consecutiveFailures, 3)
        XCTAssertEqual(paused.error, "最新失败")
        XCTAssertFalse(failures.contains { $0.contentId == recoveredId && $0.jtype == "score" })
    }

    func testResolvedAutomaticFailureIsRemovedBeforeDisplay() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sourceId: Int64 = 9_500_030
        let completedId: Int64 = 9_500_031
        let pendingId: Int64 = 9_500_032
        cleanup(ids: [completedId, pendingId])
        db.execute("DELETE FROM content_source WHERE id = ?", params: [sourceId])
        defer {
            cleanup(ids: [completedId, pendingId])
            db.execute("DELETE FROM content_source WHERE id = ?", params: [sourceId])
        }

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id, stype, name, identifier, enabled, config)
            VALUES (?, 'rss', '目标复核测试', ?, 1, '{}');
            """, params: [sourceId, "https://test.invalid/resolved-failure-\(sourceId)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content
                (id, guid, source_id, ctype, source, title, url, fetch_status,
                 auto_summarize, llm_summary)
            VALUES (?, ?, ?, 'article', 'rss', '已补齐摘要', ?, 2, 1, '摘要结果'),
                   (?, ?, ?, 'article', 'rss', '仍缺摘要', ?, 2, 1, NULL);
            """, params: [
                completedId, "resolved-guid-\(completedId)", sourceId,
                "https://test.invalid/item/\(completedId)",
                pendingId, "resolved-guid-\(pendingId)", sourceId,
                "https://test.invalid/item/\(pendingId)"]))
        for id in [completedId, pendingId] {
            for attempt in 1...3 {
                XCTAssertTrue(db.execute("""
                    INSERT INTO content_job
                        (content_id, jtype, status, finished_at, error)
                    VALUES (?, 'summarize', 3, datetime('now'), ?);
                    """, params: [id, "失败 \(attempt)"]))
            }
        }

        let failures = FailedJobService.shared.pausedFailures()

        XCTAssertFalse(failures.contains { $0.contentId == completedId })
        XCTAssertTrue(failures.contains { $0.contentId == pendingId })
        XCTAssertEqual(db.scalarInt(
            "SELECT COUNT(*) FROM content_job WHERE content_id=? AND status=3",
            params: [completedId]), 0)
        XCTAssertEqual(db.scalarInt(
            "SELECT COUNT(*) FROM content_job WHERE content_id=? AND status=3",
            params: [pendingId]), 3)
    }

    @MainActor
    func testIgnoringPermanentFailureRemovesTargetFromAllAutomaticChecks() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sourceId: Int64 = 9_500_050
        let contentId: Int64 = 9_500_051
        cleanup(ids: [contentId])
        db.execute("DELETE FROM content_source WHERE id=?", params: [sourceId])
        defer {
            cleanup(ids: [contentId])
            db.execute("DELETE FROM content_source WHERE id=?", params: [sourceId])
        }

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source(id,stype,name,identifier,enabled,config)
            VALUES (?,'rss','忽略测试源',?,1,'{}');
            """, params: [sourceId, "https://test.invalid/ignore-\(sourceId)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content
                (id,source_id,guid,ctype,source,title,url,content_md,fetch_status,auto_summarize)
            VALUES (?,?,?,'article','rss','永久失败内容',?,'正文',2,1);
            """, params: [contentId, sourceId, "ignore-guid-\(contentId)",
                             "https://test.invalid/item/\(contentId)"]))
        for attempt in 1...3 {
            XCTAssertTrue(db.execute("""
                INSERT INTO content_job(content_id,jtype,status,finished_at,error)
                VALUES (?,'summarize',3,datetime('now'),?);
                """, params: [contentId, "失败 \(attempt)"]))
        }
        let failure = try XCTUnwrap(FailedJobService.shared.pausedFailures().first {
            $0.contentId == contentId && $0.jtype == "summarize"
        })
        XCTAssertTrue(db.fetchContents(sourceId: sourceId, unmetProcessingOnly: true)
            .contains { $0.id == contentId })

        XCTAssertTrue(FailedJobService.shared.ignore(failure))
        PipelineWorker.shared.requestPendingRefresh()

        XCTAssertFalse(db.fetchContents(sourceId: sourceId, unmetProcessingOnly: true)
            .contains { $0.id == contentId })
        XCTAssertFalse(PipelineWorker.shared.pendingTaskIdsForTesting(
            ignoreWatermark: true, onlySourceId: sourceId).contains(contentId))
        XCTAssertFalse(FailedJobService.shared.pausedFailures().contains {
            $0.contentId == contentId && $0.jtype == "summarize"
        })
        XCTAssertEqual(db.scalarInt("""
            SELECT COUNT(*) FROM content_processing_ignore
            WHERE content_id=? AND jtype='summarize';
            """, params: [contentId]), 1)
    }

    private func requireIsolatedDatabase() throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向临时数据库；跳过以免触碰真实库")
        }
    }

    private func cleanup(ids: [Int64]) {
        for id in ids {
            Database.shared.execute("DELETE FROM content_job WHERE content_id = ?", params: [id])
            Database.shared.execute("DELETE FROM content WHERE id = ?", params: [id])
        }
    }
}

@MainActor
final class ManualProcessingStateStoreTests: XCTestCase {
    func testDashboardTracksAcceptedManualTaskLifecycle() {
        let store = ContentProcessingStateStore.shared
        let contentId: Int64 = 9_500_041
        store.clear(contentId: contentId)
        defer { store.clear(contentId: contentId) }

        store.enqueue(contentId: contentId, title: "单篇转录", operation: "AI 转录")
        XCTAssertEqual(store.state(for: contentId)?.phase, .queued)
        XCTAssertTrue(store.dashboardEntries.contains { $0.contentId == contentId })

        store.begin(contentId: contentId, message: "转录中…")
        XCTAssertEqual(store.state(for: contentId)?.phase, .running)
        XCTAssertEqual(store.state(for: contentId)?.title, "单篇转录")

        store.finish(contentId: contentId, message: "✅ 转录完成", succeeded: true)
        XCTAssertEqual(store.state(for: contentId)?.phase, .succeeded)
        XCTAssertTrue(store.dashboardEntries.contains { $0.contentId == contentId })
    }

    func testRejectedManualClickDoesNotCreateDashboardTask() {
        let store = ContentProcessingStateStore.shared
        let contentId: Int64 = 9_500_042
        store.clear(contentId: contentId)
        defer { store.clear(contentId: contentId) }

        store.notice(contentId: contentId, message: "该篇正在后台处理中，请稍候")

        XCTAssertFalse(store.dashboardEntries.contains { $0.contentId == contentId })
    }
}

@MainActor
final class IssueCenterStoreTests: XCTestCase {
    func testStaleSourceCreatesActionableSourceIssue() async throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向临时数据库；跳过以免触碰真实库")
        }
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sourceId: Int64 = 9_500_060
        db.execute("DELETE FROM content_source WHERE id=?", params: [sourceId])
        defer { db.execute("DELETE FROM content_source WHERE id=?", params: [sourceId]) }
        XCTAssertTrue(db.execute("""
            INSERT INTO content_source
                (id,stype,name,identifier,enabled,last_fetched_at,config)
            VALUES (?,'rss','过期源',?,1,'2020-01-01 00:00:00','{}');
            """, params: [sourceId, "https://test.invalid/stale-\(sourceId)"]))
        SourceStore.shared.reload()

        let store = IssueCenterStore()
        await store.refresh()

        XCTAssertEqual(store.status, .needsAttention)
        XCTAssertTrue(store.issues.contains {
            $0.id == "sources.rss.stale" && $0.category == .sources
                && $0.action == .sourceFailures
        })
    }
}

@MainActor
final class SourceStoreSyncGuardTests: XCTestCase {
    func testSyncAllReturnsWithoutClearingAnExistingSyncLock() async throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向临时数据库；跳过以免触碰真实库")
        }
        let store = SourceStore.shared
        store.isSyncing = true
        store.lastSyncMessage = "原任务仍在运行"
        defer {
            store.isSyncing = false
            store.lastSyncMessage = ""
        }

        await store.syncAll(manual: false)

        XCTAssertTrue(store.isSyncing)
        XCTAssertEqual(store.lastSyncMessage, "原任务仍在运行")
    }

    func testSingleSourceSyncRejectsWhenAnotherSyncIsRunning() async throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向临时数据库；跳过以免触碰真实库")
        }
        let store = SourceStore.shared
        store.isSyncing = true
        defer { store.isSyncing = false }
        let source = FeedSource(
            id: 9_510_001, stype: "rss", name: "同步锁测试",
            identifier: "https://test.invalid/feed.xml", enabled: true,
            lastFetchedAt: nil, error: nil, config: "{}", folderId: nil)

        do {
            _ = try await store.syncOne(source)
            XCTFail("已有同步运行时不应进入网络抓取")
        } catch SourceStore.SyncError.alreadyRunning {
            // expected
        } catch {
            XCTFail("应返回 alreadyRunning，而不是触发网络错误：\(error)")
        }
    }
}
