import ReadBoardUI

public enum ReadBoardReadingModePreference {
    public static func selectedMode(
        isMedia: Bool,
        articleViewMode: Int,
        mediaTab: Int,
        availableModes: [ReadBoardArticleContentMode],
        preferredMode: ReadBoardArticleContentMode
    ) -> ReadBoardArticleContentMode {
        let requested: ReadBoardArticleContentMode
        if isMedia {
            switch mediaTab {
            case 1: requested = .translated
            case 2: requested = .transcript
            default: requested = .original
            }
        } else {
            requested = articleViewMode == 1 ? .original : .translated
        }

        if availableModes.contains(requested) { return requested }
        if isMedia, availableModes.contains(.original) { return .original }
        return availableModes.contains(preferredMode)
            ? preferredMode : (availableModes.first ?? .original)
    }

    public static func articleViewMode(
        for mode: ReadBoardArticleContentMode
    ) -> Int {
        mode == .translated ? 0 : 1
    }

    public static func mediaTab(for mode: ReadBoardArticleContentMode) -> Int {
        switch mode {
        case .original: 0
        case .translated: 1
        case .transcript: 2
        }
    }
}
