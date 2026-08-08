import ReadBoardContract

extension SourceCatalogItem {
    var stype: String { sourceType }
    var folderId: Int64? { folderID }
    var fetchModeAuto: Bool { fetchModeAutomatic }
    var fetchIntervalMin: Int { fetchIntervalMinutes }
    var maxKeep: Int { maximumRetainedContent }
    var isFetchOff: Bool { fetchMode == .summary }

    var localFetchMode: FetchMode {
        FetchMode(rawValue: fetchMode.rawValue)
            ?? FetchMode.platformDefault(for: sourceType)
            ?? .summary
    }

    var localAvailableFetchModes: [FetchMode] {
        let values = availableFetchModes.compactMap { FetchMode(rawValue: $0.rawValue) }
        return values.isEmpty ? FetchMode.allCases.filter(\.isUserSelectable) : values
    }

    func localFetchModeDisplayName(_ mode: FetchMode? = nil) -> String {
        let value = mode ?? localFetchMode
        if value == .externalFulltext, let fulltextDisplayName { return fulltextDisplayName }
        return value.displayName
    }
}

extension SourceHistoryScope {
    var displayName: String {
        switch self {
        case .recent30Days: "仅最近 30 天"
        case .recentYear: "近 1 年"
        case .all: "全部历史"
        }
    }
}
