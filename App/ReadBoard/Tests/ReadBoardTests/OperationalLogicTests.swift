import XCTest
@testable import ReadBoard

final class FailedJobServiceTests: XCTestCase {
    func testRecentFailuresOnlyShowsLatestStatePerContentAndType() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let recoveredId: Int64 = 9_500_011
        let failingId: Int64 = 9_500_012
        cleanup(ids: [recoveredId, failingId])
        defer { cleanup(ids: [recoveredId, failingId]) }

        for id in [recoveredId, failingId] {
            XCTAssertTrue(db.execute("""
                INSERT INTO content (id, guid, ctype, source, title, url, fetch_status)
                VALUES (?, ?, 'article', 'rss', ?, ?, 2);
                """, params: [id, "failed-job-guid-\(id)", "失败任务测试 \(id)",
                                "https://test.invalid/item/\(id)"]))
        }
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
