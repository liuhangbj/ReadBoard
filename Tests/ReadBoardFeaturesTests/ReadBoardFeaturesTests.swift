import Foundation
import ReadBoardContract
@testable import ReadBoardFeatures
import ReadBoardUI
import XCTest

final class ReadBoardFeaturesTests: XCTestCase {
    func testSidebarUsesDampedInterfaceScale() {
        XCTAssertEqual(ReadBoardLibraryColumnMetrics.sidebarScale(for: 0.8), 0.9)
        XCTAssertEqual(ReadBoardLibraryColumnMetrics.sidebarScale(for: 1), 1)
        XCTAssertEqual(ReadBoardLibraryColumnMetrics.sidebarScale(for: 1.6), 1.3)
        XCTAssertEqual(
            ReadBoardLibraryColumnMetrics.scaledSidebarWidth(230, interfaceScale: 1.6),
            299)
    }

    func testCustomReadingFontIsLimitedToMarkdownBody() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let detailSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Reading/ReadBoardArticleDetailFeatureView.swift"),
            encoding: .utf8)
        let settingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Reading/ReadBoardReadingSettingsView.swift"),
            encoding: .utf8)
        let appearanceSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardUI/ReadBoardReadingAppearance.swift"),
            encoding: .utf8)
        let desktopSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Desktop/ReadBoardDesktopMainFeatureView.swift"),
            encoding: .utf8)
        let markdownSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardUI/ReadBoardMarkdownBodyView.swift"),
            encoding: .utf8)

        XCTAssertTrue(settingsSource.contains("settingsPicker(\"界面字体\", selection: $interfaceFontRaw)"))
        XCTAssertTrue(settingsSource.contains("settingsPicker(\"正文字体\", selection: $fontRaw)"))
        XCTAssertFalse(settingsSource.contains("正文/标题字体"))
        XCTAssertTrue(appearanceSource.contains("(\"system\", \"系统默认（苹方）\")"))
        XCTAssertTrue(desktopSource.contains(
            ".readBoardInterfaceFont(size: 13 * uiFontScale)\n"
            + "        .readBoardInterfaceFontFamily(interfaceFontRaw)"))
        XCTAssertTrue(detailSource.contains("translatedTitleFont: interfaceFont("))
        XCTAssertTrue(detailSource.contains("metadataFont: interfaceFont(size: metaFontSize)"))
        XCTAssertTrue(detailSource.contains("font: interfaceFont(size: summaryFontSize)"))
        XCTAssertTrue(detailSource.contains(".font(interfaceFont(size: titleFontSize"))
        XCTAssertFalse(detailSource.contains("design: .serif"))
        XCTAssertTrue(detailSource.contains("layoutRevision: markdownLayoutRevision"))
        XCTAssertTrue(markdownSource.contains(".id(style.layoutRevision)"))
        XCTAssertTrue(detailSource.contains("fontProvider: { size, weight, design in\n"
            + "                            ReadBoardReadingFont.font(\n"
            + "                                rawValue: fontRaw"))
    }

    func testReaderSettingsPaneUsesFullWidthPresentation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Settings/ReadBoardGeneralSettingsPane.swift"),
            encoding: .utf8)
        let readingSettingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Reading/ReadBoardReadingSettingsView.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains(
            "ReadBoardReadingSettingsView(presentation: .settingsPane)"))
        XCTAssertFalse(source.contains(
            "ReadBoardReadingSettingsView()\n"
            + "            .frame(maxWidth: .infinity"))
        XCTAssertTrue(readingSettingsSource.contains("case .popover:\n"
            + "            content.frame(width: 480, height: 620)"))
        XCTAssertTrue(readingSettingsSource.contains("case .settingsPane:\n"
            + "            content.frame(\n"
            + "                maxWidth: .infinity,"))
    }

    func testSettingsTypographyUsesFourSemanticSizesAndSharedPageHeader() throws {
        XCTAssertEqual(ReadBoardTextRole.pageTitle.size, 17)
        XCTAssertEqual(ReadBoardTextRole.sectionTitle.size, 13)
        XCTAssertEqual(ReadBoardTextRole.item.size, 11)
        XCTAssertEqual(ReadBoardTextRole.itemTitle.size, 11)
        XCTAssertEqual(ReadBoardTextRole.detail.size, 11)
        XCTAssertEqual(ReadBoardTextRole.input.size, 11)
        XCTAssertEqual(ReadBoardTextRole.micro.size, 9)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shellSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Settings/ReadBoardSettingsShell.swift"),
            encoding: .utf8)
        let designSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardUI/ReadBoardDesign.swift"),
            encoding: .utf8)
        let settingsDirectory = repositoryRoot.appendingPathComponent(
            "Sources/ReadBoardFeatures/Settings")
        let settingsFiles = try FileManager.default.contentsOfDirectory(
            at: settingsDirectory,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let settingsSource = try settingsFiles.map {
            try String(contentsOf: $0, encoding: .utf8)
        }.joined(separator: "\n")

        XCTAssertTrue(shellSource.contains(
            "ReadBoardSettingsPageContainer(title: title(for: destination))"))
        XCTAssertTrue(shellSource.contains(".readBoardInterfaceScale(uiFontScale)"))
        XCTAssertTrue(designSource.contains("public static let rowTitle: CGFloat = 13"))
        XCTAssertTrue(designSource.contains("public static let rowExcerpt: CGFloat = 11"))
        XCTAssertTrue(designSource.contains("public static let badge: CGFloat = 9"))
        XCTAssertFalse(settingsSource.contains(".font(.caption"))
        XCTAssertFalse(settingsSource.contains(".font(.callout"))
        XCTAssertFalse(settingsSource.contains(".font(.headline"))
        XCTAssertFalse(settingsSource.contains("size: 12"))
        XCTAssertFalse(settingsSource.contains("size: 14"))
        XCTAssertFalse(settingsSource.contains("size: 18"))
    }

    func testSettingsControlsUseSharedSemanticGeometry() throws {
        XCTAssertEqual(ReadBoardSettingsControlMetrics.labelWidth, 68)
        XCTAssertEqual(ReadBoardSettingsControlMetrics.numericWidth, 90)
        XCTAssertEqual(ReadBoardSettingsControlMetrics.compactWidth, 180)
        XCTAssertEqual(ReadBoardSettingsControlMetrics.standardWidth, 320)
        XCTAssertEqual(ReadBoardSettingsControlMetrics.wideWidth, 520)
        XCTAssertEqual(ReadBoardSettingsControlMetrics.controlHeight, 28)
        XCTAssertEqual(ReadBoardSettingsControlMetrics.iconButtonSize, 28)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readingSettingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Reading/ReadBoardReadingSettingsView.swift"),
            encoding: .utf8)
        let generalSettingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Settings/ReadBoardGeneralSettingsPane.swift"),
            encoding: .utf8)
        let llmSettingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Settings/ReadBoardLLMSettingsPane.swift"),
            encoding: .utf8)
        XCTAssertTrue(readingSettingsSource.contains("settingsPicker(\"主题\", selection: $themeRaw)"))
        XCTAssertTrue(readingSettingsSource.contains("settingsToggle(\"显示来源名\", isOn: $showSource)"))
        XCTAssertTrue(readingSettingsSource.contains("ReadBoardSettingsSliderRow("))
        XCTAssertFalse(readingSettingsSource.contains(".frame(width: 440)"))
        XCTAssertTrue(generalSettingsSource.contains("ReadBoardSettingsInputRow(\"代理地址\")"))
        XCTAssertTrue(generalSettingsSource.contains(".readBoardSettingsInput()"))
        XCTAssertTrue(llmSettingsSource.contains("ReadBoardSettingsSliderRow(\n"
            + "                \"温度\","))
        XCTAssertTrue(llmSettingsSource.contains("ReadBoardSettingsPasswordField("))
        XCTAssertTrue(llmSettingsSource.contains("if presetID == \"custom\""))
        XCTAssertTrue(llmSettingsSource.contains("Self.presetID(for: profile.baseURL)"))
        XCTAssertFalse(llmSettingsSource.contains("Slider(value: $temperature"))
        XCTAssertTrue(llmSettingsSource.contains("Form {"))
        XCTAssertFalse(llmSettingsSource.contains("ReadBoardPanel {"))

        let maintenanceSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Settings/ReadBoardMaintenanceSettingsPane.swift"),
            encoding: .utf8)
        let dependencySource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Settings/ReadBoardDependencySettingsPane.swift"),
            encoding: .utf8)
        XCTAssertTrue(readingSettingsSource.contains(
            ".buttonStyle(ReadBoardSecondaryButtonStyle())\n"
            + "                    .readBoardSettingsButton(.inline)"))
        XCTAssertTrue(maintenanceSource.contains(
            "Button(\"恢复\") { backupToRestore = backup }\n"
            + "                        .buttonStyle(ReadBoardSecondaryButtonStyle())"))
        XCTAssertTrue(dependencySource.contains(
            ".buttonStyle(ReadBoardSecondaryButtonStyle())\n"
            + "                    .readBoardSettingsButton(.inline)"))
    }

    func testSettingsUseSixSemanticControlFamiliesWithoutSegmentedPickers() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let uiSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardUI/ReadBoardSettingsTypography.swift"),
            encoding: .utf8)
        let settingsDirectory = repositoryRoot.appendingPathComponent(
            "Sources/ReadBoardFeatures/Settings")
        let settingsSources = try FileManager.default.contentsOfDirectory(
            at: settingsDirectory,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        for component in [
            "ReadBoardSettingsToggleRow",
            "ReadBoardSettingsPickerRow",
            "ReadBoardSettingsSliderRow",
            "ReadBoardSettingsStepperRow",
            "ReadBoardSettingsInputRow",
            "ReadBoardSettingsActionRow",
        ] {
            XCTAssertTrue(uiSource.contains("public struct \(component)"))
        }
        XCTAssertFalse(settingsSources.contains(".pickerStyle(.segmented)"))
        XCTAssertFalse(settingsSources.contains("ReadBoardSettingsSegmentedPickerRow"))
    }

    func testManagementPagesShareTheSameCenteredContentColumn() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let operationsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Operations/ReadBoardOperationsFeatureView.swift"),
            encoding: .utf8)
        let sourcesSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Sources/ReadBoardSourcesFeatureView.swift"),
            encoding: .utf8)
        let uiSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardUI/ReadBoardDesign.swift"),
            encoding: .utf8)

        XCTAssertTrue(operationsSource.contains("ReadBoardFeaturePageContainer"))
        XCTAssertTrue(sourcesSource.contains("ReadBoardFeaturePageContainer"))
        XCTAssertTrue(uiSource.contains("featurePageMaximumWidth: CGFloat = 1120"))
    }

    func testSourceFolderCollapsePersistenceRoundTrip() {
        XCTAssertEqual(
            ReadBoardSourcesFeatureView.collapsedFolderIDs(from: "9,2,invalid,9"),
            Set([2, 9]))
        XCTAssertEqual(
            ReadBoardSourcesFeatureView.collapsedFolderIDsRaw(Set([9, 2])),
            "2,9")
    }

    func testSourceManagementUsesFixedControlGroupsAndCanonicalAIOrder() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Sources/ReadBoardSourceRows.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("static let baseControlWidth: CGFloat = 108"))
        XCTAssertTrue(source.contains("static let policyControlWidth: CGFloat = 82"))
        XCTAssertTrue(source.contains("static let groupSpacing: CGFloat = 22"))
        XCTAssertTrue(source.contains("private struct SourceConfigurationLayout: Layout"))
        XCTAssertFalse(source.contains("ViewThatFits(in: .horizontal)"))
        let score = try XCTUnwrap(source.range(of: "(.score, \"AI 评分\")"))
        let summary = try XCTUnwrap(source.range(of: "(.summarize, \"AI 摘要\")"))
        let translation = try XCTUnwrap(source.range(of: "(.translate, \"AI 翻译\")"))
        let transcription = try XCTUnwrap(source.range(of: "(.transcribe, \"AI 转录\")"))
        XCTAssertLessThan(score.lowerBound, summary.lowerBound)
        XCTAssertLessThan(summary.lowerBound, translation.lowerBound)
        XCTAssertLessThan(translation.lowerBound, transcription.lowerBound)
        XCTAssertTrue(source.contains(".menuIndicator(.hidden)"))
    }

    func testSourceListPresentationGroupsOnceAndPreservesCatalogOrder() {
        let firstFolder = SourceFolderItem(id: 20, name: "第二组")
        let secondFolder = SourceFolderItem(id: 10, name: "第一组")
        let presentation = ReadBoardSourceListPresentation(snapshot: SourceCatalogSnapshot(
            sources: [
                sourceItem(id: 1, folderID: 10),
                sourceItem(id: 2, folderID: nil),
                sourceItem(id: 3, folderID: 20),
                sourceItem(id: 4, folderID: 10),
            ],
            folders: [firstFolder, secondFolder]))

        XCTAssertEqual(presentation.folderGroups.map(\.id), [20, 10])
        XCTAssertEqual(presentation.folderGroups[0].sources.map(\.id), [3])
        XCTAssertEqual(presentation.folderGroups[1].sources.map(\.id), [1, 4])
        XCTAssertEqual(presentation.ungroupedSources.map(\.id), [2])
    }

    func testMainManagementDestinationsUsePageTitles() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let desktop = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Desktop/ReadBoardDesktopMainFeatureView.swift"),
            encoding: .utf8)
        let sources = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Sources/ReadBoardSourcesFeatureView.swift"),
            encoding: .utf8)

        XCTAssertTrue(desktop.contains("title: \"运行状态\""))
        XCTAssertFalse(desktop.contains("title: \"数据看板\""))
        XCTAssertTrue(sources.contains("title: \"订阅管理\""))
        XCTAssertTrue(desktop.contains("model: sourcesModel"))
        XCTAssertTrue(sources.contains("if model.snapshot == nil { await model.load() }"))
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

    func testGlobalVideoPlayerUsesReadingColumnWidthAndSixteenByNineCanvas() throws {
        XCTAssertEqual(
            ReadBoardMediaPlayerLayout.videoAspectRatio,
            16.0 / 9.0,
            accuracy: 0.0001)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Reading/ReadBoardArticleDetailFeatureView.swift"),
            encoding: .utf8)
        let playerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Reading/ReadBoardGlobalMediaPlayer.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("let readingColumnWidth = Self.resolvedContentWidth("))
        XCTAssertTrue(source.contains("mediaPlayer\n                            .frame(width: readingColumnWidth)"))
        XCTAssertFalse(source.contains("width: min(\n                                    640,"))
        XCTAssertTrue(playerSource.contains(
            "Color.black\n                    .aspectRatio(\n"
            + "                        ReadBoardMediaPlayerLayout.videoAspectRatio"))
        XCTAssertTrue(playerSource.contains(
            "videoSurface\n                            .frame(maxWidth: .infinity, maxHeight: .infinity)"))
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

    func testGlobalPlaybackItemKeepsPlatformSpecificEngineAndArtwork() {
        let bilibiliSummary = playbackSummary(
            contentType: "video",
            source: "bilibili",
            sourceType: "bilibili",
            url: "https://www.bilibili.com/video/BV1TEST",
            imageURL: "https://example.com/cover.jpg")
        let videoDetail = ContentDetail(
            id: bilibiliSummary.id,
            contentMarkdown: nil,
            translatedMarkdown: nil,
            transcriptMarkdown: nil,
            translatedTitle: nil,
            audioURL: nil,
            videoID: "BV1TEST",
            score: nil,
            summary: nil)

        let bilibili = ReadBoardPlaybackItem.make(
            summary: bilibiliSummary, detail: videoDetail)
        XCTAssertEqual(bilibili?.kind, .bilibili)
        XCTAssertEqual(bilibili?.videoID, "BV1TEST")
        XCTAssertEqual(bilibili?.artworkURL?.absoluteString, "https://example.com/cover.jpg")

        let youtubeSummary = playbackSummary(
            contentType: "youtube",
            source: "youtube",
            sourceType: "youtube",
            url: "https://www.youtube.com/watch?v=abc",
            imageURL: nil)
        let youtube = ReadBoardPlaybackItem.make(
            summary: youtubeSummary,
            detail: ContentDetail(
                id: youtubeSummary.id,
                contentMarkdown: nil,
                translatedMarkdown: nil,
                transcriptMarkdown: nil,
                translatedTitle: nil,
                audioURL: nil,
                videoID: "abc",
                score: nil,
                summary: nil))
        XCTAssertEqual(youtube?.kind, .youtube)
        XCTAssertEqual(youtube?.artworkURL?.absoluteString, "https://i.ytimg.com/vi/abc/hqdefault.jpg")

        let audioSummary = playbackSummary(
            contentType: "podcast",
            source: "podcast",
            sourceType: "podcast",
            url: "https://example.com/episode",
            imageURL: nil)
        let audio = ReadBoardPlaybackItem.make(
            summary: audioSummary,
            detail: ContentDetail(
                id: audioSummary.id,
                contentMarkdown: nil,
                translatedMarkdown: nil,
                transcriptMarkdown: nil,
                translatedTitle: nil,
                audioURL: "https://example.com/episode.mp3",
                videoID: nil,
                score: nil,
                summary: nil))
        XCTAssertEqual(audio?.kind, .audio)
        XCTAssertEqual(audio?.mediaURL?.absoluteString, "https://example.com/episode.mp3")
    }

    func testGlobalPlayerLivesAboveLibraryAndReaderMediaIsOutsideBodyScroll() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let desktopSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Desktop/ReadBoardDesktopMainFeatureView.swift"),
            encoding: .utf8)
        let detailSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Reading/ReadBoardArticleDetailFeatureView.swift"),
            encoding: .utf8)
        let playerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ReadBoardFeatures/Reading/ReadBoardGlobalMediaPlayer.swift"),
            encoding: .utf8)

        XCTAssertTrue(desktopSource.contains("@State private var mediaPlayer: ReadBoardGlobalMediaPlayer"))
        XCTAssertTrue(desktopSource.contains("ReadBoardMiniPlayerView("))
        XCTAssertTrue(desktopSource.contains("playbackNavigationRequest: playbackNavigationRequest"))
        XCTAssertTrue(detailSource.contains("if playbackItem != nil {\n                        mediaPlayer"))
        XCTAssertTrue(detailSource.contains(".task(id: playbackItem?.id)"))
        XCTAssertTrue(detailSource.contains("globalMediaPlayer.prepare(item)"))
        XCTAssertTrue(detailSource.contains("globalMediaPlayer?.discardPrepared(itemID: itemID)"))
        let scrollStart = try XCTUnwrap(detailSource.range(of: "ScrollView {"))
        let headerStart = try XCTUnwrap(detailSource.range(of: "articleHeader", range: scrollStart.lowerBound..<detailSource.endIndex))
        XCTAssertLessThan(scrollStart.lowerBound, headerStart.lowerBound)
        let mediaStart = try XCTUnwrap(detailSource.range(of: "if playbackItem != nil"))
        XCTAssertLessThan(mediaStart.lowerBound, scrollStart.lowerBound)
        XCTAssertTrue(playerSource.contains("https://www.youtube.com/iframe_api"))
        XCTAssertTrue(playerSource.contains("https://player.bilibili.com/player.html"))
        XCTAssertTrue(playerSource.contains("ReadBoardWebParkingSurface(player: player)"))
        XCTAssertTrue(playerSource.contains("public private(set) var hasUserStartedPlayback = false"))
        XCTAssertTrue(desktopSource.contains(
            "if mediaPlayer.hasUserStartedPlayback, mediaPlayer.item != nil"))
        XCTAssertTrue(playerSource.contains(
            "Text(ReadBoardAudioPlayback.formatTime(player.duration))"))
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

        let sourceRecovering = ReadBoardServiceHealthSummary(
            runtime: RuntimeStatusSnapshot(),
            authentications: [],
            problems: OperationalProblemCounts(),
            recoveringSourceIssues: 145)
        XCTAssertEqual(sourceRecovering.phase, .repairing)
        XCTAssertEqual(sourceRecovering.issueCount, 145)

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

    private func playbackSummary(
        contentType: String,
        source: String,
        sourceType: String?,
        url: String,
        imageURL: String?
    ) -> ContentSummary {
        ContentSummary(
            id: 999,
            contentType: contentType,
            source: source,
            sourceType: sourceType,
            sourceID: 1,
            sourceName: "测试源",
            title: "测试媒体",
            author: nil,
            url: url,
            language: nil,
            publishedAt: nil,
            excerpt: nil,
            score: nil,
            summary: nil,
            fetchStatus: 2,
            isRead: false,
            isStarred: false,
            imageURL: imageURL,
            hasTranslation: false,
            hasTranscript: false,
            isMedia: true,
            translatedHead: nil,
            translatedTitle: nil,
            hasFulltext: false,
            hasExport: false,
            hasUnmetProcessing: false,
            accessState: nil)
    }

    private func sourceItem(id: Int64, folderID: Int64?) -> SourceCatalogItem {
        SourceCatalogItem(
            id: id,
            sourceType: "rss",
            name: "源 \(id)",
            identifier: "https://test.invalid/\(id)",
            enabled: true,
            lastFetchedAt: nil,
            error: nil,
            folderID: folderID,
            policy: SourcePolicySnapshot(),
            fetchMode: .summary,
            fetchModeAutomatic: false,
            fetchIntervalMinutes: 60,
            maximumRetainedContent: 0,
            transcribable: false)
    }
}
