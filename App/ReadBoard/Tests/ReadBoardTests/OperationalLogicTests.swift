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
