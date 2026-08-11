import Foundation
import ReadBoardContract
import ReadBoardFeatures
import XCTest

final class ReadBoardFeaturesTests: XCTestCase {
    func testOperationsBoardCentersItsConstrainedContentColumn() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Operations/ReadBoardOperationsFeatureView.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains(
            ".frame(maxWidth: 1120, alignment: .leading)\n"
            + "            .frame(maxWidth: .infinity, alignment: .top)"))
    }

    func testReaderRootFillsTheSplitDetailBeforeCenteringContent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Reading/ReadBoardArticleDetailFeatureView.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains(
            ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"))
    }

    func testReadingColumnUsesExactCenteredSafeWidth() {
        XCTAssertEqual(
            ReadBoardArticleDetailFeatureView.resolvedContentWidth(
                availableWidth: 1_400, preferredWidth: 720, horizontalPadding: 24),
            720)
        XCTAssertEqual(
            ReadBoardArticleDetailFeatureView.resolvedContentWidth(
                availableWidth: 640, preferredWidth: 1_000, horizontalPadding: 24),
            592)
    }

    func testReadingModePreferenceMatchesCorePersistenceSemantics() {
        XCTAssertEqual(
            ReadBoardReadingModePreference.selectedMode(
                isMedia: false, articleViewMode: 0, mediaTab: 0,
                availableModes: [.original, .translated], preferredMode: .translated),
            .translated)
        XCTAssertEqual(
            ReadBoardReadingModePreference.selectedMode(
                isMedia: false, articleViewMode: 1, mediaTab: 0,
                availableModes: [.original, .translated], preferredMode: .translated),
            .original)
        XCTAssertEqual(
            ReadBoardReadingModePreference.selectedMode(
                isMedia: true, articleViewMode: 0, mediaTab: 2,
                availableModes: [.original, .transcript], preferredMode: .original),
            .transcript)
        XCTAssertEqual(
            ReadBoardReadingModePreference.selectedMode(
                isMedia: true, articleViewMode: 0, mediaTab: 2,
                availableModes: [.original], preferredMode: .original),
            .original)
        XCTAssertEqual(ReadBoardReadingModePreference.articleViewMode(for: .translated), 0)
        XCTAssertEqual(ReadBoardReadingModePreference.articleViewMode(for: .original), 1)
        XCTAssertEqual(ReadBoardReadingModePreference.mediaTab(for: .transcript), 2)
    }

    func testPermissionsRequireBothScopeAndCapability() {
        let permissions = ReadBoardFeaturePermissions(
            capabilities: [.library, .processing],
            scopes: [.readLibrary, .runProcessing])

        XCTAssertTrue(permissions.allows(.readLibrary, capability: .library))
        XCTAssertTrue(permissions.allows(.runProcessing, capability: .processing))
        XCTAssertFalse(permissions.allows(.manageSources, capability: .sourceManagement))
        XCTAssertFalse(permissions.allows(.runProcessing, capability: .administration))
    }

    func testLibraryLocationAppliesFolderAndSourceFilters() {
        let base = ContentQuery(
            filter: ContentFilter(readState: .unread, keyword: "energy"),
            sort: .oldest,
            pageSize: 75,
            cursor: "next")

        let folder = ReadBoardLibraryLocation.folder(id: 12, name: "深度")
            .applying(to: base)
        XCTAssertEqual(folder.filter.folderID, 12)
        XCTAssertNil(folder.filter.sourceID)
        XCTAssertEqual(folder.filter.readState, .unread)
        XCTAssertEqual(folder.filter.keyword, "energy")

        let source = ReadBoardLibraryLocation.source(id: 99, name: "示例源")
            .applying(to: base)
        XCTAssertEqual(source.filter.sourceID, 99)
        XCTAssertNil(source.filter.folderID)
        XCTAssertEqual(source.sort, .oldest)
        XCTAssertEqual(source.cursor, "next")
    }

    func testAudioPlaybackControlsKeepCoreBehavior() {
        XCTAssertEqual(ReadBoardAudioPlayback.clampedTime(-15, duration: 100), 0)
        XCTAssertEqual(ReadBoardAudioPlayback.clampedTime(35, duration: 100), 35)
        XCTAssertEqual(ReadBoardAudioPlayback.clampedTime(130, duration: 100), 100)
        XCTAssertEqual(ReadBoardAudioPlayback.clampedTime(.infinity, duration: 100), 0)
        XCTAssertEqual(ReadBoardAudioPlayback.formatTime(65), "1:05")
        XCTAssertEqual(ReadBoardAudioPlayback.formatTime(3_661), "1:01:01")
        XCTAssertEqual(ReadBoardAudioPlayback.formatTime(.nan), "0:00")
        XCTAssertEqual(ReadBoardAudioPlayback.formatRate(0.75), "0.75×")
        XCTAssertEqual(ReadBoardAudioPlayback.formatRate(1), "1×")
        XCTAssertEqual(ReadBoardAudioPlayback.formatRate(1.25), "1.25×")
        XCTAssertEqual(ReadBoardAudioPlayback.formatRate(1.5), "1.5×")
        XCTAssertEqual(ReadBoardAudioPlayback.formatRate(2), "2×")
    }

    func testBilibiliVideoUsesItsOwnSharedPlayer() {
        XCTAssertEqual(ReadBoardVideoPlayerPlatform.resolve(source: "bilibili"), .bilibili)
        XCTAssertEqual(ReadBoardVideoPlayerPlatform.resolve(source: "youtube"), .youtube)
        XCTAssertEqual(ReadBoardVideoPlayerPlatform.resolve(source: "video"), .youtube)
        XCTAssertEqual(ReadBoardVideoPlayerPlatform.resolve(
            source: "video", pageURL: URL(string: "https://www.bilibili.com/video/BV1")), .bilibili)
    }

    func testOPMLParserPreservesFoldersTypesAndPolicies() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><body>
          <outline text="视频">
            <outline text="示例频道" xmlUrl="https://youtube.com/@example"
              sourceType="youtube" fetchMode="youtube_subtitle"
              auto_score="true" auto_translate="1" />
          </outline>
          <outline text="普通 RSS" xmlUrl="https://example.com/feed.xml" />
        </body></opml>
        """

        let items = try ReadBoardOPMLParser.parse(Data(xml.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].name, "示例频道")
        XCTAssertEqual(items[0].folderName, "视频")
        XCTAssertEqual(items[0].sourceType, "youtube")
        XCTAssertEqual(items[0].fetchMode, .youtubeSubtitle)
        XCTAssertTrue(items[0].policy.autoScore)
        XCTAssertTrue(items[0].policy.autoTranslate)
        XCTAssertEqual(items[1].sourceType, "article")
        XCTAssertNil(items[1].folderName)
        XCTAssertEqual(items[1].fetchMode, .automatic)
    }

    func testServiceHealthPrioritizesManualProblemsOverAutomaticRepair() {
        let healthy = ReadBoardServiceHealthSummary(
            runtime: RuntimeStatusSnapshot(),
            authentications: [],
            problems: OperationalProblemCounts())
        XCTAssertEqual(healthy.phase, .healthy)

        let repairing = ReadBoardServiceHealthSummary(
            runtime: RuntimeStatusSnapshot(phase: .working),
            authentications: [],
            problems: OperationalProblemCounts(fullTextFailures: 2))
        XCTAssertEqual(repairing.phase, .repairing)

        let manual = ReadBoardServiceHealthSummary(
            runtime: RuntimeStatusSnapshot(phase: .working, pausedFailureCount: 1),
            authentications: [PlatformAuthenticationStatus(
                platformID: "wechat",
                displayName: "微信",
                phase: .expired)],
            problems: OperationalProblemCounts(exportFailures: 2))
        XCTAssertEqual(manual.phase, .needsAttention)
        XCTAssertEqual(manual.issueCount, 4)
    }
}
