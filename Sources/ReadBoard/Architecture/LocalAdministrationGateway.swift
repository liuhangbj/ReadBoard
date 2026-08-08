import Foundation
import ReadBoardContract

public struct LocalAdministrationGateway: AdministrationGateway {
    public init() {}

    public func dashboardStatistics() async -> DashboardStatistics {
        await Task.detached(priority: .userInitiated) {
            let value = StatsService.shared.overview()
            return DashboardStatistics(
                overview: StatisticsOverview(
                    totalSources: value.totalSources, enabledSources: value.enabledSources,
                    totalContent: value.totalContent, unreadCount: value.unreadCount,
                    starredCount: value.starredCount, duplicateCount: value.duplicateCount,
                    withFulltext: value.withFulltext, scored: value.scored,
                    translated: value.translated, summarized: value.summarized,
                    tagCount: value.tagCount, folderCount: value.folderCount,
                    jobTotal: value.jobTotal, jobFailed: value.jobFailed,
                    databaseSizeMB: value.dbSizeMB),
                jobs: StatsService.shared.jobByType().map {
                    JobTypeStatistics(jobType: $0.jtype, succeeded: $0.ok, failed: $0.failed)
                },
                topSources: StatsService.shared.topSources().map {
                    RankedSource(name: $0.name, count: $0.count)
                },
                exports: StatsService.shared.exportRecords().map {
                    ExportActivity(platform: $0.platform, title: $0.title, status: $0.status, time: $0.time)
                })
        }.value
    }

    public func filterRules() async -> [FilterRuleRecord] {
        await Task.detached { FilterService.shared.allRules().map(Self.record) }.value
    }

    public func createFilterRule(_ rule: FilterRuleRecord) async -> Bool {
        await Task.detached { FilterService.shared.addRule(Self.rule(rule)) }.value
    }

    public func updateFilterRule(_ rule: FilterRuleRecord) async {
        await Task.detached { FilterService.shared.updateRule(Self.rule(rule)) }.value
    }

    public func deleteFilterRule(id: Int64) async {
        await Task.detached { FilterService.shared.removeRule(id: id) }.value
    }

    public func processingFailures() async -> [ContentProcessingFailure] {
        await Task.detached {
            FailedJobService.shared.pausedFailures().map {
                ContentProcessingFailure(id: $0.id, contentID: $0.contentId, title: $0.title,
                    sourceName: $0.sourceName, jobType: $0.jtype, error: $0.error,
                    consecutiveFailures: $0.consecutiveFailures)
            }
        }.value
    }

    public func retryProcessingFailure(id: Int64) async -> Bool {
        guard let failure = await Task.detached(operation: {
            FailedJobService.shared.pausedFailures().first { $0.id == id }
        }).value else { return false }
        return await FailedJobService.shared.retry(failure)
    }

    public func ignoreProcessingFailure(id: Int64) async -> Bool {
        await Task.detached {
            guard let failure = FailedJobService.shared.pausedFailures().first(where: { $0.id == id }) else {
                return false
            }
            return FailedJobService.shared.ignore(failure)
        }.value
    }

    public func fullTextFailures(limit: Int) async -> [FullTextFailure] {
        await Task.detached {
            Database.shared.queryRows("""
                SELECT c.id, c.title, c.url, c.fetch_error, c.updated_at,
                       s.name AS source_name, s.stype
                FROM content c JOIN content_source s ON s.id=c.source_id
                WHERE c.fetch_status=3 AND c.deleted_at IS NULL AND c.is_duplicate=0
                  AND c.fetch_engine LIKE '%_connector'
                ORDER BY c.updated_at DESC, c.id DESC LIMIT ?;
                """, params: [limit]).compactMap { row in
                    guard let id = Int64(row["id"] ?? "") else { return nil }
                    return FullTextFailure(id: id, title: row["title"] ?? "(无标题)",
                        sourceName: row["source_name"] ?? row["stype"] ?? "外部平台",
                        sourceType: row["stype"] ?? "external", url: row["url"] ?? "",
                        error: row["fetch_error"] ?? "平台未返回可用正文", updatedAt: row["updated_at"])
                }
        }.value
    }

    public func operationalProblemCounts() async -> OperationalProblemCounts {
        await Task.detached {
            let fulltext = Database.shared.queryRows("""
                SELECT COUNT(*) AS failures,
                       SUM(CASE WHEN updated_at <= datetime('now', '-24 hours') THEN 1 ELSE 0 END) AS persistent
                FROM content WHERE fetch_status=3 AND deleted_at IS NULL AND is_duplicate=0
                  AND fetch_engine LIKE '%_connector';
                """).first
            let exports = Database.shared.queryRows("""
                SELECT COUNT(*) AS failures, COUNT(DISTINCT er.rule_id) AS rules
                FROM export_record er JOIN export_rule r ON r.id=er.rule_id AND r.revision=er.revision
                WHERE r.enabled=1 AND er.status='failed';
                """).first
            return OperationalProblemCounts(
                fullTextFailures: Int(fulltext?["failures"] ?? "0") ?? 0,
                persistentFullTextFailures: Int(fulltext?["persistent"] ?? "0") ?? 0,
                exportFailures: Int(exports?["failures"] ?? "0") ?? 0,
                affectedExportRules: Int(exports?["rules"] ?? "0") ?? 0)
        }.value
    }

    private static func record(_ value: FilterRule) -> FilterRuleRecord {
        FilterRuleRecord(id: value.id, name: value.name, field: value.field,
                         matchType: value.matchType, pattern: value.pattern,
                         action: value.action, sourceID: value.sourceId, enabled: value.enabled)
    }

    private static func rule(_ value: FilterRuleRecord) -> FilterRule {
        FilterRule(id: value.id, name: value.name, field: value.field,
                   matchType: value.matchType, pattern: value.pattern,
                   action: value.action, sourceId: value.sourceID, enabled: value.enabled)
    }
}
