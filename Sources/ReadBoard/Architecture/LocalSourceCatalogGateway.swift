import Foundation
import ReadBoardContract

public final class LocalSourceCatalogGateway: SourceCatalogGateway, @unchecked Sendable {
    private let database: Database

    init(database: Database = .shared) {
        self.database = database
    }

    public func snapshot() async throws -> SourceCatalogSnapshot {
        let rows = await Task.detached(priority: .utility) { [database] in
            database.queryRows("""
                SELECT s.id, s.stype, s.name, s.identifier, s.enabled,
                       s.last_fetched_at, s.error, s.config, s.folder_id,
                       COALESCE(c.content_count, 0) AS content_count
                FROM content_source s
                LEFT JOIN (
                    SELECT source_id, COUNT(*) AS content_count
                    FROM content
                    GROUP BY source_id
                ) c ON c.source_id=s.id
                ORDER BY s.stype, s.name;
                """)
        }.value
        let folderRows = await Task.detached(priority: .utility) { [database] in
            database.queryRows("SELECT id, name FROM folder ORDER BY name;")
        }.value
        let status = await MainActor.run {
            (
                SourceStore.shared.isSyncing,
                SourceStore.shared.isExternalSyncing,
                SourceStore.shared.lastSyncMessage
            )
        }
        let connectorMetadata = await MainActor.run {
            Dictionary(uniqueKeysWithValues:
                ReadBoardSourceConnectorRegistry.shared.connectorsSupportingAddSource().map {
                    ($0.sourceType, ($0.fulltextMode, $0.fulltextDisplayName))
                })
        }
        return SourceCatalogSnapshot(
            sources: rows.map { Self.makeSource($0, connectorMetadata: connectorMetadata) },
            folders: folderRows.map {
                SourceFolderItem(
                    id: Int64($0["id"] ?? "0") ?? 0,
                    name: $0["name"] ?? "")
            },
            isSyncing: status.0,
            isExternalSyncing: status.1,
            lastSyncMessage: status.2)
    }

    private static func makeSource(
        _ row: [String: String],
        connectorMetadata: [String: (FetchMode, String)]
    ) -> SourceCatalogItem {
        let type = row["stype"] ?? "rss"
        let config = configuration(row["config"])
        let modeRaw = config["fetch_mode"] as? String
            ?? FetchMode.platformDefault(for: type)?.rawValue
            ?? SourceFetchMode.summary.rawValue
        let mode = SourceFetchMode(rawValue: modeRaw) ?? .summary
        let lastFetchedAt = row["last_fetched_at"]
        return SourceCatalogItem(
            id: Int64(row["id"] ?? "0") ?? 0,
            sourceType: type,
            name: row["name"] ?? "",
            identifier: row["identifier"] ?? "",
            enabled: row["enabled"] == "1",
            lastFetchedAt: lastFetchedAt,
            error: row["error"].flatMap { $0.isEmpty ? nil : $0 },
            folderID: row["folder_id"].flatMap(Int64.init),
            policy: SourcePolicySnapshot(
                autoScore: flag("auto_score", in: config),
                autoTranslate: flag("auto_translate", in: config),
                autoTranscribe: flag("auto_transcribe", in: config),
                autoSummarize: flag("auto_summarize", in: config)),
            fetchMode: mode,
            fetchModeAutomatic: flag("fetch_mode_auto", in: config),
            fetchIntervalMinutes: integer("fetch_interval_min", in: config, default: 60),
            maximumRetainedContent: integer("max_keep", in: config, default: 0),
            contentCount: Int(row["content_count"] ?? "0") ?? 0,
            hoursSinceFetch: hoursSince(lastFetchedAt),
            transcribable: ["podcast", "youtube", "bilibili"].contains(type),
            availableFetchModes: availableModes(type: type, connector: connectorMetadata[type]?.0),
            fulltextDisplayName: connectorMetadata[type]?.1)
    }

    private static func availableModes(type: String, connector: FetchMode?) -> [SourceFetchMode] {
        if let platform = FetchMode.platformDefault(for: type) ?? connector {
            return [platform, .summary].compactMap { SourceFetchMode(rawValue: $0.rawValue) }
        }
        return FetchMode.allCases.filter(\.isUserSelectable)
            .compactMap { SourceFetchMode(rawValue: $0.rawValue) }
    }

    private static func configuration(_ raw: String?) -> [String: Any] {
        guard let raw,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func flag(_ key: String, in config: [String: Any]) -> Bool {
        (config[key] as? Bool) ?? ((config[key] as? Int) == 1)
    }

    private static func integer(_ key: String, in config: [String: Any], default value: Int) -> Int {
        if let integer = config[key] as? Int { return integer }
        if let double = config[key] as? Double { return Int(double) }
        return value
    }

    private static func hoursSince(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let date = formatter.date(from: value) else { return nil }
        return Date().timeIntervalSince(date) / 3600
    }
}
