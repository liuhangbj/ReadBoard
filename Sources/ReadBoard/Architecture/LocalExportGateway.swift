import Foundation
import ReadBoardContract

public final class LocalExportGateway: ExportGateway, @unchecked Sendable {
    private let service: ExportService

    init(service: ExportService = .shared) {
        self.service = service
    }

    public func rules() async throws -> [ExportRuleDTO] {
        await Task.detached(priority: .utility) { [service] in
            service.listRules().map(Self.makeDTO)
        }.value
    }

    public func save(rule: ExportRuleDTO) async throws -> ExportRuleDTO {
        let trimmed = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExportGatewayError.invalidRule }
        var normalized = rule
        normalized.name = trimmed
        let savedID = await Task.detached(priority: .userInitiated) { [service] in
            service.saveRule(Self.makeModel(normalized))
        }.value
        guard savedID > 0 else {
            throw ExportGatewayError.operationFailed("保存导出规则失败")
        }
        guard let saved = try await rules().first(where: { $0.id == savedID }) else {
            throw ExportGatewayError.ruleNotFound(savedID)
        }
        return saved
    }

    public func delete(ruleID: Int64) async throws {
        guard ruleID > 0 else { throw ExportGatewayError.invalidRule }
        await Task.detached(priority: .userInitiated) { [service] in
            service.deleteRule(id: ruleID)
        }.value
    }

    public func stats(ruleID: Int64) async throws -> ExportRuleStatsDTO {
        let stats = await Task.detached(priority: .utility) { [service] in
            service.statsFor(ruleId: ruleID)
        }.value
        return ExportRuleStatsDTO(delivered: stats.delivered, failed: stats.failed)
    }

    public func preview(rule: ExportRuleDTO) async throws -> ExportRulePreviewDTO {
        let preview = await Task.detached(priority: .userInitiated) { [service] in
            service.preview(rule: Self.makeModel(rule))
        }.value
        return ExportRulePreviewDTO(
            matchingCount: preview.matchingCount,
            samples: preview.samples.map {
                .init(
                    contentID: $0.contentId,
                    title: $0.title,
                    markdown: $0.markdown,
                    destination: $0.destination,
                    issue: $0.issue)
            })
    }

    public func run(ruleID: Int64) async throws -> ExportExecutionResult {
        guard try await rules().contains(where: { $0.id == ruleID }) else {
            throw ExportGatewayError.ruleNotFound(ruleID)
        }
        await service.runFor(ruleId: ruleID)
        return ExportExecutionResult(affectedRuleCount: 1, message: "导出规则执行完成")
    }

    public func forceExport(contentID: Int64) async throws -> ExportExecutionResult {
        let count = await service.forceExport(contentId: contentID)
        return ExportExecutionResult(
            affectedRuleCount: count,
            message: "已触发 \(count) 条导出规则")
    }

    private static func makeDTO(_ rule: ExportRule) -> ExportRuleDTO {
        ExportRuleDTO(
            id: rule.id,
            name: rule.name,
            enabled: rule.enabled,
            criteria: .init(
                minimumScore: rule.criteria.minScore,
                sourceIDs: rule.criteria.sourceIds,
                folderIDs: rule.criteria.folderIds,
                requireTranslated: rule.criteria.requireTranslated,
                requireTranscribed: rule.criteria.requireTranscribed,
                requireSummary: rule.criteria.requireSummary,
                requireScored: rule.criteria.requireScored,
                starredOnly: rule.criteria.starredOnly,
                readStatus: rule.criteria.readStatus,
                keywords: rule.criteria.keywords,
                contentTypes: rule.criteria.contentTypes,
                languages: rule.criteria.languages,
                platforms: rule.criteria.platforms,
                excludedSourceIDs: rule.criteria.excludedSourceIds,
                excludedKeywords: rule.criteria.excludedKeywords,
                publishedAfter: rule.criteria.publishedAfter,
                publishedBefore: rule.criteria.publishedBefore),
            trigger: rule.triggerOn,
            target: rule.target,
            lastRunAt: rule.lastRunAt,
            revision: rule.revision,
            artifact: rule.effectiveArtifact,
            missingPolicy: rule.missingPolicy,
            outputFormat: rule.outputFormat,
            subfolderTemplate: rule.effectiveSubfolderTemplate,
            titleTemplate: rule.titleTemplate,
            writePolicy: rule.effectiveWritePolicy,
            historyScope: rule.historyScope,
            frontmatterFields: rule.frontmatterFields,
            attachmentsPolicy: rule.attachmentsPolicy,
            createdAt: rule.createdAt,
            useTranslatedTitle: rule.useTranslatedTitle,
            frontmatterLabels: rule.frontmatterLabels,
            historyAfter: rule.historyAfter,
            scheduleInterval: rule.targetConfig["schedule_interval"] as? String ?? "daily")
    }

    private static func makeModel(_ dto: ExportRuleDTO) -> ExportRule {
        var targetConfig: [String: Any] = [
            "view": dto.artifact,
            "subfolder": dto.subfolderTemplate,
            "overwrite": dto.writePolicy == "overwrite",
            "use_translated_title": dto.useTranslatedTitle,
            "schedule_interval": dto.scheduleInterval
        ]
        if let labels = dto.frontmatterLabels { targetConfig["frontmatter_labels"] = labels }
        if let historyAfter = dto.historyAfter { targetConfig["history_after"] = historyAfter }
        var rule = ExportRule(
            id: dto.id,
            name: dto.name,
            enabled: dto.enabled,
            criteria: makeCriteria(dto.criteria),
            triggerOn: dto.trigger,
            target: dto.target,
            targetConfig: targetConfig,
            lastRunAt: dto.lastRunAt)
        rule.revision = dto.revision
        rule.artifact = dto.artifact
        rule.missingPolicy = dto.missingPolicy
        rule.outputFormat = dto.outputFormat
        rule.subfolderTemplate = dto.subfolderTemplate
        rule.titleTemplate = dto.titleTemplate
        rule.writePolicy = dto.writePolicy
        rule.overwrite = dto.writePolicy == "overwrite"
        rule.historyScope = dto.historyScope
        rule.frontmatterFields = dto.frontmatterFields
        rule.attachmentsPolicy = dto.attachmentsPolicy
        rule.createdAt = dto.createdAt
        rule.useTranslatedTitle = dto.useTranslatedTitle
        rule.frontmatterLabels = dto.frontmatterLabels
        rule.historyAfter = dto.historyAfter
        return rule
    }

    private static func makeCriteria(_ dto: ExportRuleDTO.Criteria) -> ExportRule.Criteria {
        var criteria = ExportRule.Criteria()
        criteria.minScore = dto.minimumScore
        criteria.sourceIds = dto.sourceIDs
        criteria.folderIds = dto.folderIDs
        criteria.requireTranslated = dto.requireTranslated
        criteria.requireTranscribed = dto.requireTranscribed
        criteria.requireSummary = dto.requireSummary
        criteria.requireScored = dto.requireScored
        criteria.starredOnly = dto.starredOnly
        criteria.readStatus = dto.readStatus
        criteria.keywords = dto.keywords
        criteria.contentTypes = dto.contentTypes
        criteria.languages = dto.languages
        criteria.platforms = dto.platforms
        criteria.excludedSourceIds = dto.excludedSourceIDs
        criteria.excludedKeywords = dto.excludedKeywords
        criteria.publishedAfter = dto.publishedAfter
        criteria.publishedBefore = dto.publishedBefore
        return criteria
    }
}
