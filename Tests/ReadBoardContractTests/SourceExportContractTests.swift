import XCTest
@testable import ReadBoardContract

final class SourceExportContractTests: XCTestCase {
    func testSourceMaintenanceValuesRoundTrip() throws {
        let scope = SourceScope(kind: .folder, id: 42)
        let data = try JSONEncoder().encode(scope)
        XCTAssertEqual(try JSONDecoder().decode(SourceScope.self, from: data), scope)

        let settings = SourceSyncSettings(enabled: true, intervalMinutes: 30)
        let settingsData = try JSONEncoder().encode(settings)
        XCTAssertEqual(
            try JSONDecoder().decode(SourceSyncSettings.self, from: settingsData),
            settings)
        XCTAssertEqual(SourcePolicyKey(rawValue: "auto_summarize"), .summarize)
        XCTAssertEqual(SourceFetchMode(rawValue: "bilibili_subtitle"), .bilibiliSubtitle)
    }

    func testExportRuleRoundTripPreservesTypedConfiguration() throws {
        let rule = ExportRuleDTO(
            id: 7,
            name: "远程导出规则",
            criteria: .init(
                minimumScore: 80,
                sourceIDs: [1, 2],
                requireSummary: true,
                keywords: ["架构"]),
            trigger: "scheduled",
            artifact: "summary_original",
            subfolderTemplate: "{source}/{year}",
            writePolicy: "versioned",
            frontmatterLabels: ["title": "标题"],
            scheduleInterval: "weekly")

        let data = try JSONEncoder().encode(rule)
        XCTAssertEqual(try JSONDecoder().decode(ExportRuleDTO.self, from: data), rule)
    }

    func testCatalogAndRuntimeSnapshotsRoundTrip() throws {
        let source = SourceCatalogItem(
            id: 10,
            sourceType: "bilibili",
            name: "测试 UP 主",
            identifier: "123",
            enabled: true,
            lastFetchedAt: "2026-08-08 10:00:00",
            error: nil,
            folderID: 2,
            policy: .init(autoScore: true, autoSummarize: true),
            fetchMode: .bilibiliSubtitle,
            fetchModeAutomatic: false,
            fetchIntervalMinutes: 30,
            maximumRetainedContent: 200,
            contentCount: 18,
            hoursSinceFetch: 1.5,
            transcribable: true)
        let catalog = SourceCatalogSnapshot(
            sources: [source],
            folders: [.init(id: 2, name: "视频")],
            lastSyncMessage: "刷新完成",
            updatedAt: 100)
        let catalogData = try JSONEncoder().encode(catalog)
        XCTAssertEqual(
            try JSONDecoder().decode(SourceCatalogSnapshot.self, from: catalogData),
            catalog)

        let runtime = RuntimeStatusSnapshot(
            phase: .working,
            lastSummary: "处理中",
            queue: .init(score: 2, items: 2, unread: 1),
            activeItems: [.init(id: 9, title: "内容", stage: "评分")],
            processedCount: 20,
            pausedFailureCount: 1,
            updatedAt: 100)
        let runtimeData = try JSONEncoder().encode(runtime)
        XCTAssertEqual(
            try JSONDecoder().decode(RuntimeStatusSnapshot.self, from: runtimeData),
            runtime)
        XCTAssertTrue(runtime.isRunning)
    }

    func testSourceOnboardingRequestsRoundTrip() throws {
        let request = SourceCreationRequest(
            identifier: "https://example.com/feed.xml",
            name: "示例源",
            sourceType: "article",
            folderID: 3,
            policy: .init(autoScore: true, autoTranslate: true),
            fetchMode: .feedFull,
            historyScope: .recentYear,
            refreshAfterCreation: false)
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(
            try JSONDecoder().decode(SourceCreationRequest.self, from: data),
            request)

        let item = SourceBatchImportItem(
            id: "candidate-1",
            name: "批量源",
            identifier: "https://example.com/import.xml",
            sourceType: "podcast",
            folderName: "播客",
            policy: .init(autoTranscribe: true),
            fetchMode: .feedFull)
        let itemData = try JSONEncoder().encode(item)
        XCTAssertEqual(
            try JSONDecoder().decode(SourceBatchImportItem.self, from: itemData),
            item)
    }
}
