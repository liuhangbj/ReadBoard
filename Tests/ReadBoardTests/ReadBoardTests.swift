import XCTest
import AppKit
@testable import ReadBoard

// MARK: - 纯逻辑单元测试（不触网、不触库——触库的走集成测试）

final class PlatformSubtitleFetchModeTests: XCTestCase {
    func testYouTubeStreamCacheExpiresAndSeparatesVideoIds() async throws {
        let cache = YouTubeStreamURLCache(ttl: 10)
        let now = Date(timeIntervalSince1970: 1_000)
        let first = try XCTUnwrap(URL(string: "https://cdn.example/video-a.mp4"))
        let second = try XCTUnwrap(URL(string: "https://cdn.example/video-b.mp4"))
        await cache.store(first, for: "a", now: now)
        await cache.store(second, for: "b", now: now)
        let aBeforeExpiry = await cache.value(for: "a", now: now.addingTimeInterval(9))
        let bBeforeExpiry = await cache.value(for: "b", now: now.addingTimeInterval(9))
        let aAtExpiry = await cache.value(for: "a", now: now.addingTimeInterval(10))
        let bStillValid = await cache.value(for: "b", now: now.addingTimeInterval(9))
        XCTAssertEqual(aBeforeExpiry, first)
        XCTAssertEqual(bBeforeExpiry, second)
        XCTAssertNil(aAtExpiry)
        XCTAssertEqual(bStillValid, second)
    }

    func testYouTubeStreamResolutionWhenNetworkTestsEnabled() async throws {
        guard ProcessInfo.processInfo.environment["READBOARD_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("网络播放地址回归测试默认关闭")
        }
        let url = try await YouTubeStreamResolver.resolve(videoId: "CABDIzdTNLU")
        XCTAssertTrue(url.scheme == "https" || url.scheme == "http")
    }

    func testYouTubeResolverProcessStopsPromptlyOnCancellation() async throws {
        let started = Date()
        let task = Task {
            try await YouTubeStreamResolver.runProcessForTesting(
                "/bin/sh", args: ["-c", "sleep 10; echo late"], timeout: 20)
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消后不应返回进程输出")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testBilibiliVideoUsesItsOwnPlayer() {
        XCTAssertEqual(VideoPlayerPlatform.resolve(source: "bilibili"), .bilibili)
        XCTAssertEqual(VideoPlayerPlatform.resolve(source: "youtube"), .youtube)
        XCTAssertEqual(VideoPlayerPlatform.resolve(source: "video"), .youtube)
    }

    func testPlatformModesComeFromSourceType() {
        XCTAssertEqual(FetchMode.platformDefault(for: "youtube"), .youtubeSubtitle)
        XCTAssertEqual(FetchMode.platformDefault(for: "bilibili"), .bilibiliSubtitle)
        XCTAssertNil(FetchMode.platformDefault(for: "rss"))
        XCTAssertNil(FetchMode.platformDefault(for: "video"))
    }

    func testVideoFeedKindDoesNotForceAPlatformMode() {
        let entry = ParsedEntry(
            guid: "video-1", title: "普通视频 RSS", url: "https://example.invalid/video",
            published: nil, html: String(repeating: "正文", count: 500), author: nil,
            meta: ["video_id": "not-a-youtube-platform-proof"])
        let feed = ParsedFeed(title: "普通视频", siteURL: nil, entries: [entry])
        XCTAssertEqual(feed.kind, .video)
        XCTAssertEqual(FullTextFetcher.shared.probeMode(forFeed: feed), .feedFull)
    }

    func testBilibiliSubtitleJSONBecomesParagraphMarkdown() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "body": [
                ["from": 0, "to": 1, "content": "第一句。"],
                ["from": 1, "to": 2, "content": "第二句。"],
                ["from": 2, "to": 3, "content": "第二句。"]
            ]
        ])
        let markdown = try XCTUnwrap(BilibiliFetcher.parseSubtitleMarkdown(data))
        XCTAssertTrue(markdown.contains("第一句。第二句。"))
        XCTAssertEqual(markdown.components(separatedBy: "第二句。").count - 1, 1)
    }

    func testYouTubePrefersOriginalAutomaticCaption() {
        let metadata: [String: Any] = [
            "automatic_captions": [
                "zh-Hans": [["ext": "json3", "url": "https://example.invalid/translated"]],
                "en-orig": [["ext": "json3", "url": "https://example.invalid/original"]]
            ]
        ]
        XCTAssertEqual(
            YouTubeSubtitleFetcher.selectedTrackURL(from: metadata)?.absoluteString,
            "https://example.invalid/original")
    }

    func testYouTubeJSON3BecomesReadableMarkdown() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "events": [
                ["segs": [["utf8": "Hello"], ["utf8": " world."]]],
                ["segs": [["utf8": "This is ReadBoard."]]]
            ]
        ])
        let markdown = try XCTUnwrap(YouTubeSubtitleFetcher.parseSubtitleMarkdown(data))
        XCTAssertEqual(markdown, "Hello world. This is ReadBoard.")
    }

    func testYouTubeNetworkSubtitleExtractionWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["READBOARD_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("网络字幕回归测试默认关闭")
        }
        let markdown = try await YouTubeSubtitleFetcher.fetchMarkdown(
            videoURL: "https://www.youtube.com/watch?v=CABDIzdTNLU")
        XCTAssertGreaterThan(try XCTUnwrap(markdown).count, 1_000)
    }

    func testBilibiliNetworkSubtitleExtractionWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["READBOARD_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("网络字幕回归测试默认关闭")
        }
        guard BilibiliAuth.sessdata != nil else { throw XCTSkip("当前测试进程没有 Bilibili 登录态") }
        let videoURL = ProcessInfo.processInfo.environment["READBOARD_BILIBILI_TEST_URL"]
            ?? "https://www.bilibili.com/video/BV1z63862ERk/"
        let markdown = try await BilibiliFetcher.fetchSubtitleMarkdown(
            videoURL: videoURL)
        XCTAssertGreaterThan(try XCTUnwrap(markdown, "该视频没有返回可用字幕：\(videoURL)").count, 1_000)
    }
}

final class TruncateKeepEndsTests: XCTestCase {

    func testShortTextUnchanged() {
        let s = "短文本不需要截断"
        XCTAssertEqual(LLMPipeline.truncateKeepEnds(s, maxChars: 100), s)
    }

    func testExactLimitUnchanged() {
        let s = String(repeating: "a", count: 100)
        XCTAssertEqual(LLMPipeline.truncateKeepEnds(s, maxChars: 100), s)
    }

    func testLongTextKeepsHeadAndTail() {
        let head = String(repeating: "H", count: 6000)
        let mid = String(repeating: "M", count: 8000)
        let tail = String(repeating: "T", count: 6000)
        let s = head + mid + tail  // 20000 字
        let out = LLMPipeline.truncateKeepEnds(s, maxChars: 12000)
        // 头部保留
        XCTAssertTrue(out.hasPrefix("HHHH"), "应保留开头")
        // 尾部保留
        XCTAssertTrue(out.hasSuffix("TTTT"), "应保留结尾")
        // 有省略标记
        XCTAssertTrue(out.contains("中段已省略"), "应有省略标记，实际: \(out.prefix(200))...")
        // 总长被压到接近上限（头60%+尾30%+标记，应远小于原文）
        XCTAssertLessThan(out.count, s.count)
        // 省略字数 = 20000 - 7200 - 3600 = 9200
        XCTAssertTrue(out.contains("9200"), "省略标记应含被省略字数 9200，实际: \(out)")
    }

    func testPurePrefixTruncationLosesTail_butKeepEndsPreserves() {
        // 回归：老实现 prefix(12000) 会丢结尾结论，新实现必须保住
        let body = String(repeating: "正", count: 11000) + "结论：买入黄金"
        let out = LLMPipeline.truncateKeepEnds(body, maxChars: 12000)
        XCTAssertTrue(out.hasSuffix("结论：买入黄金"), "结尾结论必须保留")
    }
}

final class TranslationChunkingTests: XCTestCase {
    func testProblemArticleLengthIsSplitIntoSafeChunksWithoutLoss() {
        let text = String(repeating: "文", count: 12_643)
        let chunks = LLMPipeline.translationChunks(text)
        XCTAssertEqual(chunks.map(\.count), [6_000, 6_000, 643])
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= LLMPipeline.maxSingleTranslationChars })
    }

    func testParagraphBoundariesArePreservedWhenPossible() {
        let paragraphs = [String(repeating: "甲", count: 3_000),
                          String(repeating: "乙", count: 2_000),
                          String(repeating: "丙", count: 2_000)]
        let text = paragraphs.joined(separator: "\n\n")
        let chunks = LLMPipeline.translationChunks(text)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.joined(separator: "\n\n"), text)
    }

    func testFallbackErrorKeepsEveryModelReason() {
        let reason = LLMPipeline.describeError(
            LLMError.providersFailed("deepseek-v4-flash：最终内容为空；kimi-k2p6：请求超时"))
        XCTAssertTrue(reason.contains("deepseek-v4-flash"))
        XCTAssertTrue(reason.contains("kimi-k2p6"))
        XCTAssertTrue(reason.contains("请求超时"))
    }
}

final class ParseScoreJSONTests: XCTestCase {

    func testValidJSON() {
        let text = #"{"depth":35,"quality":30,"readability":20,"total":85,"summary":"好文"}"#
        let r = LLMPipeline.parseScoreJSON(text)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.depth, 35)
        XCTAssertEqual(r?.quality, 30)
        XCTAssertEqual(r?.readability, 20)
        XCTAssertEqual(r?.total, 85)
        XCTAssertEqual(r?.summary, "好文")
    }

    func testHallucinatedOversizeClamped() {
        // LLM 幻觉：depth=95 超上限 40 → 钳到 40；total 与分项差>10 → 以分项和为准
        let text = #"{"depth":95,"quality":30,"readability":20,"total":145,"summary":"x"}"#
        let r = LLMPipeline.parseScoreJSON(text)
        XCTAssertEqual(r?.depth, 40)
        XCTAssertEqual(r?.total, 40 + 30 + 20)  // 分项和 90，不是 145
    }

    func testTotalZeroFallsBackToSum() {
        let text = #"{"depth":30,"quality":25,"readability":15,"total":0}"#
        let r = LLMPipeline.parseScoreJSON(text)
        XCTAssertEqual(r?.total, 70)
    }

    func testWrappedInProse() {
        let text = "以下是评分：\n{\"depth\":30,\"quality\":25,\"readability\":15,\"total\":70,\"summary\":\"s\"}\n希望有帮助"
        let r = LLMPipeline.parseScoreJSON(text)
        XCTAssertEqual(r?.total, 70)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(LLMPipeline.parseScoreJSON("完全不是 JSON"))
        XCTAssertNil(LLMPipeline.parseScoreJSON(""))
    }

    func testCustomWeightsRecomputeTotalFromFixedDimensions() {
        let text = #"{"depth":20,"quality":20,"readability":20,"total":999,"summary":"x"}"#
        let result = LLMPipeline.parseScoreJSON(
            text, weights: ScoreWeights(depth: 60, quality: 20, readability: 20))
        XCTAssertEqual(result?.total, 57)
    }
}

final class ParseTranslateFullJSONTests: XCTestCase {
    func testValidTranslationIsAccepted() {
        let text = #"{"title":"译文标题","translation":"完整译文","depth":30,"quality":25,"readability":20,"summary":"摘要"}"#
        let result = LLMPipeline.parseTranslateFullJSON(text)
        XCTAssertEqual(result?.translation, "完整译文")
    }

    func testMissingOrEmptyTranslationIsRejected() {
        let missing = #"{"title":"标题","depth":30,"quality":25,"readability":20,"summary":"摘要"}"#
        let empty = #"{"title":"标题","translation":"  \n ","depth":30,"quality":25,"readability":20,"summary":"摘要"}"#
        XCTAssertNil(LLMPipeline.parseTranslateFullJSON(missing))
        XCTAssertNil(LLMPipeline.parseTranslateFullJSON(empty))
    }

    func testObviouslyIncompleteTranslationIsRejectedAgainstSourceLength() {
        let refusal = #"{"title":"标题","translation":"原文未提供，无法完成翻译。","depth":0,"quality":0,"readability":0,"summary":""}"#
        XCTAssertNil(LLMPipeline.parseTranslateFullJSON(refusal, sourceLength: 500))
    }
}

final class ExportCriteriaTests: XCTestCase {

    func testRoundTrip() {
        var c = ExportRule.Criteria()
        c.minScore = 70
        c.sourceIds = [1, 2, 3]
        c.requireTranslated = true
        c.starredOnly = true
        let json = c.toJSON()
        let back = ExportRule.Criteria.from(json: json)
        XCTAssertEqual(back.minScore, 70)
        XCTAssertEqual(back.sourceIds, [1, 2, 3])
        XCTAssertTrue(back.requireTranslated)
        XCTAssertTrue(back.starredOnly)
        XCTAssertFalse(back.requireTranscribed)
    }

    func testEmptyJSONDefaults() {
        let c = ExportRule.Criteria.from(json: "{}")
        XCTAssertNil(c.minScore)
        XCTAssertNil(c.sourceIds)
        XCTAssertFalse(c.requireTranslated)
        XCTAssertFalse(c.requireSummary)
    }

    func testGarbageJSONDefaults() {
        let c = ExportRule.Criteria.from(json: "not json")
        XCTAssertNil(c.minScore)
    }
}

final class AIPromptSettingsTests: XCTestCase {
    func testDefaultModeDoesNotInjectCustomInstruction() {
        withRestoredSettings(keys: [AIPromptSettings.modeKey(for: .score),
                                    AIPromptSettings.scoreDepthWeightKey]) {
            AIPromptSettings.setMode(.default, for: .score)
            UserDefaults.standard.set(80, forKey: AIPromptSettings.scoreDepthWeightKey)
            XCTAssertEqual(AIPromptSettings.instructionBlock(for: .score), "")
            XCTAssertEqual(AIPromptSettings.scoreWeights, .default)
        }
    }

    func testScoreWeightsAreNormalizedAndStitchedIntoPrompt() {
        withRestoredSettings(keys: [AIPromptSettings.modeKey(for: .score),
                                    AIPromptSettings.scoreDepthWeightKey,
                                    AIPromptSettings.scoreQualityWeightKey,
                                    AIPromptSettings.scoreReadabilityWeightKey]) {
            AIPromptSettings.setMode(.custom, for: .score)
            UserDefaults.standard.set(60, forKey: AIPromptSettings.scoreDepthWeightKey)
            UserDefaults.standard.set(20, forKey: AIPromptSettings.scoreQualityWeightKey)
            UserDefaults.standard.set(20, forKey: AIPromptSettings.scoreReadabilityWeightKey)
            XCTAssertEqual(AIPromptSettings.scoreWeights,
                           ScoreWeights(depth: 60, quality: 20, readability: 20))
            let block = AIPromptSettings.instructionBlock(for: .score)
            XCTAssertTrue(block.contains("内容深度 60%"))
            XCTAssertTrue(block.contains("信息质量 20%"))
            XCTAssertTrue(block.contains("不得改变程序规定的输出格式"))
        }
    }

    func testSummaryLengthAndStyleBecomeControlledRequirements() {
        withRestoredSettings(keys: [AIPromptSettings.modeKey(for: .summarize),
                                    AIPromptSettings.summaryLengthKey,
                                    AIPromptSettings.summaryStyleKey]) {
            AIPromptSettings.setMode(.custom, for: .summarize)
            UserDefaults.standard.set(200, forKey: AIPromptSettings.summaryLengthKey)
            UserDefaults.standard.set("bullets", forKey: AIPromptSettings.summaryStyleKey)
            XCTAssertEqual(AIPromptSettings.summaryLength, 200)
            let block = AIPromptSettings.instructionBlock(for: .summarize)
            XCTAssertTrue(block.contains("摘要长度控制在 200 字以内。"))
            XCTAssertTrue(block.contains("Markdown 要点列表"))
        }
    }

    func testTranslationFieldsIncludeStyleLanguageAndTerms() {
        withRestoredSettings(keys: [AIPromptSettings.modeKey(for: .translate),
                                    AIPromptSettings.translationStyleKey,
                                    AIPromptSettings.translationLanguageKey,
                                    AIPromptSettings.translationTermsKey]) {
            AIPromptSettings.setMode(.custom, for: .translate)
            UserDefaults.standard.set("faithful", forKey: AIPromptSettings.translationStyleKey)
            UserDefaults.standard.set("ja", forKey: AIPromptSettings.translationLanguageKey)
            UserDefaults.standard.set("公司名保留英文", forKey: AIPromptSettings.translationTermsKey)
            XCTAssertEqual(AIPromptSettings.effectiveTranslationLanguage(), "日文")
            let block = AIPromptSettings.instructionBlock(for: .translate)
            XCTAssertTrue(block.contains("输出语言为日文"))
            XCTAssertTrue(block.contains("准确忠实"))
            XCTAssertTrue(block.contains("公司名保留英文"))
        }
    }

    func testTranscriptOptionsControlSpeechStyleAndTranslation() {
        withRestoredSettings(keys: [AIPromptSettings.modeKey(for: .transcribe),
                                    AIPromptSettings.transcriptSpeechStyleKey,
                                    AIPromptSettings.transcriptTranslateKey]) {
            AIPromptSettings.setMode(.custom, for: .transcribe)
            UserDefaults.standard.set("written", forKey: AIPromptSettings.transcriptSpeechStyleKey)
            UserDefaults.standard.set(false, forKey: AIPromptSettings.transcriptTranslateKey)
            XCTAssertFalse(AIPromptSettings.transcriptTranslationEnabled)
            let block = AIPromptSettings.instructionBlock(for: .transcribe)
            XCTAssertTrue(block.contains("偏书面表达"))
            XCTAssertTrue(block.contains("不执行翻译"))
        }
    }

    private func withRestoredSettings(keys: [String], body: () -> Void) {
        let defaults = UserDefaults.standard
        let oldValues = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let oldValue = oldValues[key] ?? nil { defaults.set(oldValue, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        body()
    }
}

final class MediaTabTests: XCTestCase {

    func testOriginalOnly() {
        XCTAssertEqual(tabIds(translation: false, transcript: false), [0])
    }

    func testTranslationOnly() {
        XCTAssertEqual(tabIds(translation: true, transcript: false), [0, 1])
    }

    func testTranscriptOnly() {
        XCTAssertEqual(tabIds(translation: false, transcript: true), [0, 2])
    }

    func testTranslationAndTranscript() {
        XCTAssertEqual(tabIds(translation: true, transcript: true), [0, 1, 2])
    }

    private func tabIds(translation: Bool, transcript: Bool) -> [Int] {
        ReadingView.mediaTabOptions(hasTranslation: translation, hasTranscript: transcript)
            .map { $0.0 }
    }
}

final class MediaAudioURLResolverTests: XCTestCase {
    func testLoadedAudioURLWins() {
        XCTAssertEqual(
            MediaAudioURLResolver.preferred("https://cdn.example/loaded.mp3", "https://feed.example/item.mp3"),
            "https://cdn.example/loaded.mp3"
        )
    }

    func testFallsBackToItemAudioURL() {
        XCTAssertEqual(
            MediaAudioURLResolver.preferred(nil, "https://feed.example/item.mp3"),
            "https://feed.example/item.mp3"
        )
    }

    func testSkipsEmptyAudioURL() {
        XCTAssertEqual(
            MediaAudioURLResolver.preferred("  \n", "https://feed.example/item.mp3"),
            "https://feed.example/item.mp3"
        )
    }

    func testAllMissingReturnsNil() {
        XCTAssertNil(MediaAudioURLResolver.preferred(nil, ""))
    }
}

final class PodcastPageResolverTests: XCTestCase {
    func testApplePodcastID() throws {
        let url = try XCTUnwrap(URL(string: "https://podcasts.apple.com/cn/podcast/大内密谈/id657765158"))
        XCTAssertEqual(FeedFetcher.applePodcastID(from: url), "657765158")
    }

    func testXimalayaCategoryPageBecomesXMLFeed() throws {
        let url = try XCTUnwrap(URL(string: "https://www.ximalaya.com/yule/8583636/"))
        XCTAssertEqual(
            FeedFetcher.ximalayaFeedURL(from: url),
            "https://www.ximalaya.com/album/8583636.xml"
        )
    }

    func testXimalayaAlbumPageBecomesXMLFeed() throws {
        let url = try XCTUnwrap(URL(string: "https://m.ximalaya.com/album/8583636"))
        XCTAssertEqual(
            FeedFetcher.ximalayaFeedURL(from: url),
            "https://www.ximalaya.com/album/8583636.xml"
        )
    }

    func testXimalayaSoundPageIsNotTreatedAsAlbum() throws {
        let url = try XCTUnwrap(URL(string: "https://www.ximalaya.com/sound/123456"))
        XCTAssertNil(FeedFetcher.ximalayaFeedURL(from: url))
    }

    func testLizhiEscapedPageDataBecomesRSSFeed() {
        let html = #"{\"userInfo\":{\"userId\":\"198\",\"band\":\"14275\"}}"#
        XCTAssertEqual(
            FeedFetcher.lizhiFeedURL(fromHTML: html),
            "https://rss.lizhi.fm/rss/14275.xml"
        )
    }

    func testLizhiHTTPFeedIsCanonicalizedToHTTPS() {
        XCTAssertEqual(
            FeedFetcher.canonicalPlatformFeedURL("http://rss.lizhi.fm/rss/14275.xml"),
            "https://rss.lizhi.fm/rss/14275.xml"
        )
        XCTAssertEqual(
            FeedFetcher.canonicalPlatformFeedURL("http://example.com/feed.xml"),
            "http://example.com/feed.xml"
        )
    }
}

final class ReadStateOverrideTests: XCTestCase {
    @MainActor
    func testOptimisticReadStatePrecedesListSnapshot() {
        let item = makeItem(readAt: nil)
        let vm = ContentViewModel()

        XCTAssertFalse(vm.effectiveIsRead(item))

        // open() 会即时更新 selectedItem，但行内覆盖为规避表格重入会稍后到达。
        vm.selectedItem = item.markingRead()
        XCTAssertTrue(vm.effectiveIsRead(item))

        // 显式覆盖优先级最高，可把列表中的旧“已读”快照即时显示为未读。
        vm.readMarks[item.id] = false
        XCTAssertFalse(vm.effectiveIsRead(item))
        vm.readMarks[item.id] = true
        XCTAssertTrue(vm.effectiveIsRead(item))
    }

    private func makeItem(readAt: String?) -> ContentItem {
        ContentItem(id: 1, ctype: "article", source: "test", title: "test", author: nil,
                    url: "https://example.com", language: nil, publishedAt: nil, excerpt: nil,
                    contentMd: nil, llmScore: nil, llmSummary: nil, llmTranslatedMd: nil,
                    fetchStatus: 0, feedId: nil, audioUrl: nil, readAt: readAt,
                    starred: false)
    }
}

final class WorkerCancellationTests: XCTestCase {
    private actor JobRecorder {
        private(set) var records: [(contentId: Int64, ok: Bool, error: String?)] = []

        func append(contentId: Int64, ok: Bool, error: String?) {
            records.append((contentId, ok, error))
        }

        var count: Int { records.count }
    }

    func testRecognizesSwiftCancellation() {
        XCTAssertTrue(LLMClient.isCancellation(CancellationError()))
    }

    func testRecognizesURLSessionCancellation() {
        XCTAssertTrue(LLMClient.isCancellation(URLError(.cancelled)))
    }

    func testDoesNotTreatOrdinaryNetworkFailureAsCancellation() {
        XCTAssertFalse(LLMClient.isCancellation(URLError(.timedOut)))
    }

    func testWorkerTimeoutReturnsPromptlyForCooperativeOperation() async {
        let started = Date()
        let result = await PipelineWorker.withTimeout(seconds: 0.05) {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return true
            } catch {
                return false
            }
        }
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testCancellingExternalProcessReturnsPromptly() async {
        let pipeline = TranscribePipeline()
        let started = Date()
        let task = Task {
            do {
                try await pipeline.run("/bin/sleep", ["5"], timeout: 5)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let wasCancelled = await task.value
        XCTAssertTrue(wasCancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testTranscriptionCancellationErrorDoesNotRecordFailure() async {
        let recorder = JobRecorder()
        let pipeline = TranscribePipeline(jobRecorder: { contentId, ok, error in
            await recorder.append(contentId: contentId, ok: ok, error: error)
        })

        let result = await pipeline.finishAfterFailure(contentId: 42, error: CancellationError())
        let recordCount = await recorder.count

        XCTAssertFalse(result)
        XCTAssertEqual(recordCount, 0)
    }

    func testCancelledTranscriptionTaskDoesNotRecordOrdinaryErrorAsFailure() async {
        let recorder = JobRecorder()
        let pipeline = TranscribePipeline(jobRecorder: { contentId, ok, error in
            await recorder.append(contentId: contentId, ok: ok, error: error)
        })
        let task = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return await pipeline.finishAfterFailure(
                contentId: 43, error: TranscribeError.downloadFailed("测试错误"))
        }

        task.cancel()
        let result = await task.value
        let recordCount = await recorder.count

        XCTAssertFalse(result)
        XCTAssertEqual(recordCount, 0)
    }

    func testRealTranscriptionErrorStillRecordsFailure() async {
        let recorder = JobRecorder()
        let pipeline = TranscribePipeline(jobRecorder: { contentId, ok, error in
            await recorder.append(contentId: contentId, ok: ok, error: error)
        })

        let result = await pipeline.finishAfterFailure(
            contentId: 44, error: TranscribeError.downloadFailed("真实失败"))

        XCTAssertFalse(result)
        let records = await recorder.records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.contentId, 44)
        XCTAssertEqual(records.first?.ok, false)
        XCTAssertTrue(records.first?.error?.contains("真实失败") == true)
    }
}

final class ContentLanguageTests: XCTestCase {
    func testNormalizesCommonLanguageCodes() {
        XCTAssertEqual(ContentLanguage.normalize(" zh_CN "), "zh-cn")
        XCTAssertEqual(ContentLanguage.normalize("cmn"), "zh")
        XCTAssertEqual(ContentLanguage.normalize("ENG"), "en")
        XCTAssertNil(ContentLanguage.normalize("und"))
    }

    func testChineseTranscriptSkipsTranslationWithoutFeedLanguage() {
        let transcript = "这是一段中文播客的完整转录内容，讨论科技行业和人工智能的发展趋势。"
        XCTAssertTrue(ContentLanguage.looksChinese(transcript))
        XCTAssertFalse(ContentLanguage.shouldTranslateTranscript(declared: nil, transcript: transcript))
        XCTAssertFalse(ContentLanguage.shouldTranslateTranscript(declared: "zh-CN", transcript: transcript))
        XCTAssertEqual(ContentLanguage.resolvedAfterTranscription(
            declared: nil, transcript: transcript), "zh")
    }

    func testEnglishTranscriptStillNeedsTranslation() {
        let transcript = "This is a sufficiently long English podcast transcript about technology and markets."
        XCTAssertTrue(ContentLanguage.shouldTranslateTranscript(declared: "en-US", transcript: transcript))
    }

    func testJapaneseTextIsNotMisclassifiedAsChinese() {
        let transcript = "これは日本語のポッドキャストです。今日は人工知能と市場について詳しく話します。"
        XCTAssertFalse(ContentLanguage.looksChinese(transcript))
    }
}

final class TranscriptPostProcessModeTests: XCTestCase {
    func testDeclaredChineseUsesLLMPolishWithoutTranslation() {
        XCTAssertEqual(
            TranscribePipeline.llmPostProcessMode(
                declaredLanguage: "zh-CN", transcript: "这是一段中文转录稿，需要整理断句和段落。"),
            .polishOnly)
    }

    func testDetectedChineseUsesLLMPolishWithoutTranslation() {
        XCTAssertEqual(
            TranscribePipeline.llmPostProcessMode(
                declaredLanguage: nil,
                transcript: "这是一段没有语言标签的中文视频转录内容，需要进行文本梳理和段落整理。"),
            .polishOnly)
    }

    func testEnglishUsesBilingualTranslation() {
        XCTAssertEqual(
            TranscribePipeline.llmPostProcessMode(
                declaredLanguage: "en-US",
                transcript: "This English transcript should be polished and translated into a bilingual document."),
            .bilingualTranslation)
    }

    func testDisablingTranslationStillPolishesEnglishInOriginalLanguage() {
        XCTAssertEqual(
            TranscribePipeline.llmPostProcessMode(
                declaredLanguage: "en-US",
                transcript: "This transcript should be polished without translation.",
                translateEnabled: false),
            .polishOnly)
    }

    func testLongSingleParagraphIsSplitWithoutLosingTranscript() {
        let transcript = String(repeating: "中文转录内容", count: 4_000)
        let chunks = LLMPipeline.splitByParagraph(transcript, maxChars: 12_000)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), transcript)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 12_000 })
    }
}

final class SanitizeFilenameTests: XCTestCase {

    func testStripsPathSeparators() {
        XCTAssertFalse(ExportService.sanitizeFilename("a/b\\c:d").contains("/"))
        XCTAssertFalse(ExportService.sanitizeFilename("a/b\\c:d").contains("\\"))
        XCTAssertFalse(ExportService.sanitizeFilename("a/b\\c:d").contains(":"))
    }

    func testEmptyBecomesUntitled() {
        XCTAssertEqual(ExportService.sanitizeFilename("///"), "untitled")
        XCTAssertEqual(ExportService.sanitizeFilename(""), "untitled")
    }

    func testNormalTitlePreserved() {
        XCTAssertEqual(ExportService.sanitizeFilename("黄金创历史新高"), "黄金创历史新高")
    }
}

final class DependencyPathsTests: XCTestCase {

    func testUserDefaultsRoundTrip() {
        let kind = DependencyPaths.Kind.ffmpeg
        DependencyPaths.setCustom(kind, "/tmp/fake-ffmpeg")
        let (path, isCustom) = DependencyPaths.current(kind)
        XCTAssertEqual(path, "/tmp/fake-ffmpeg")
        XCTAssertTrue(isCustom)
        // 清除后回自动
        DependencyPaths.setCustom(kind, "")
        let (path2, isCustom2) = DependencyPaths.current(kind)
        XCTAssertFalse(isCustom2)
        _ = path2  // 自动探测结果不断言（取决于本机）
    }

    func testKindsAllHaveCommonPaths() {
        for k in DependencyPaths.Kind.allCases {
            XCTAssertFalse(k.commonPaths.isEmpty, "\(k) 应有常见位置候选")
        }
    }
}

final class SecretStoreTests: XCTestCase {

    func testSaveLoadDelete() {
        let key = "test.readboard.xctest"
        _ = SecretStore.delete(forKey: key)
        XCTAssertTrue(SecretStore.save("secret-token-123", forKey: key))
        XCTAssertEqual(SecretStore.load(forKey: key), "secret-token-123")
        XCTAssertTrue(SecretStore.exists(forKey: key))
        XCTAssertTrue(SecretStore.delete(forKey: key))
        XCTAssertNil(SecretStore.load(forKey: key))
        XCTAssertFalse(SecretStore.exists(forKey: key))
    }

    func testOverwrite() {
        let key = "test.readboard.overwrite"
        _ = SecretStore.delete(forKey: key)
        XCTAssertTrue(SecretStore.save("v1", forKey: key))
        XCTAssertTrue(SecretStore.save("v2", forKey: key))
        XCTAssertEqual(SecretStore.load(forKey: key), "v2")
        XCTAssertTrue(SecretStore.delete(forKey: key))
    }
}

// MARK: - feed 解析（content:encoded 优先级 + 嵌套 CDATA）

final class FeedParseTests: XCTestCase {

    /// 嵌套 CDATA 壳剥除（机器之心 feed 的双层转义）
    func testStripNestedCDATA() {
        XCTAssertEqual(FeedFetcher.stripNestedCDATA("<![CDATA[<p>正文</p>]]>"), "<p>正文</p>")
        XCTAssertEqual(FeedFetcher.stripNestedCDATA("普通 html"), "普通 html")
        XCTAssertEqual(FeedFetcher.stripNestedCDATA(""), "")
    }

    /// content:encoded 全文应覆盖 description 摘要
    func testContentEncodedOverridesDescription() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel><title>t</title>
        <item>
          <title>文章</title>
          <link>https://x.com/1</link>
          <guid>g1</guid>
          <description>一句话摘要</description>
          <content:encoded>&lt;p&gt;这是完整正文，比摘要长很多很多很多很多&lt;/p&gt;</content:encoded>
        </item>
        </channel></rss>
        """
        let entries = FeedFetcher.parseFeedForTest(xml: xml)?.entries ?? []
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].html.contains("完整正文"), "content:encoded 应覆盖 description")
        XCTAssertFalse(entries[0].html.contains("<![CDATA"), "不应残留 CDATA 壳")
    }

    /// 嵌套 CDATA 的 content:encoded 剥壳
    func testNestedCDATAStripped() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel><title>t</title>
        <item>
          <title>a</title><link>https://x.com/2</link><guid>g2</guid>
          <content:encoded>&lt;![CDATA[&lt;p&gt;双层转义正文&lt;/p&gt;]]&gt;</content:encoded>
        </item>
        </channel></rss>
        """
        let entries = FeedFetcher.parseFeedForTest(xml: xml)?.entries ?? []
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].html, "<p>双层转义正文</p>")
    }

    func testRSSChannelLanguageFlowsIntoEntries() throws {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel>
          <title>中文播客</title><language>zh_CN</language>
          <item><title>第一期</title><guid>zh-1</guid><link>https://x.com/zh-1</link></item>
        </channel></rss>
        """
        let feed = try XCTUnwrap(FeedFetcher.parseFeedForTest(xml: xml))
        XCTAssertEqual(feed.language, "zh-cn")
        XCTAssertEqual(feed.entries.first?.language, "zh-cn")
    }

    func testAtomRootLanguageFlowsIntoEntries() throws {
        let xml = """
        <?xml version="1.0"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xml:lang="zh-Hans">
          <title>中文频道</title>
          <entry><id>yt-1</id><title>中文视频</title><link href="https://x.com/yt-1"/></entry>
        </feed>
        """
        let feed = try XCTUnwrap(FeedFetcher.parseFeedForTest(xml: xml))
        XCTAssertEqual(feed.language, "zh-hans")
        XCTAssertEqual(feed.entries.first?.language, "zh-hans")
    }

    func testVideoEnclosureIsAPlayablePodcastCarrier() throws {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel><title>视频播客</title>
          <item><title>Video Edition</title><guid>video-podcast-1</guid>
            <link>https://x.com/video-podcast-1</link>
            <enclosure url="https://cdn.example/episode.mp4" length="12345" type="video/mp4"/>
          </item>
        </channel></rss>
        """
        let feed = try XCTUnwrap(FeedFetcher.parseFeedForTest(xml: xml))
        let entry = try XCTUnwrap(feed.entries.first)
        XCTAssertEqual(feed.kind, .podcast)
        XCTAssertEqual(entry.meta["video_url"], "https://cdn.example/episode.mp4")
        XCTAssertEqual(entry.meta["enclosure_type"], "video/mp4")
        XCTAssertEqual(SourceStore.contentType(source: "podcast", meta: entry.meta), "podcast")
    }
}

// MARK: - Markdown 解析

final class MarkdownParseTests: XCTestCase {

    func testHeadings() {
        let blocks = MarkdownRenderer.parse("# 一级\n## 二级\n正文")
        guard case .heading(let l1, _) = blocks[0], case .heading(let l2, _) = blocks[1] else {
            XCTFail("应解析出两个标题"); return
        }
        XCTAssertEqual(l1, 1); XCTAssertEqual(l2, 2)
    }

    func testParagraphMerge() {
        let blocks = MarkdownRenderer.parse("第一行\n第二行\n\n新段落")
        let paras = blocks.filter { if case .paragraph = $0 { return true }; return false }
        XCTAssertEqual(paras.count, 2, "连续行合并为一段，空行分段")
    }

    func testListAndQuote() {
        let blocks = MarkdownRenderer.parse("- 列表项\n> 引用")
        guard case .listItem(let ordered, _, _) = blocks[0], case .quote = blocks[1] else {
            XCTFail("应解析出列表项和引用"); return
        }
        XCTAssertFalse(ordered)
    }

    func testCodeBlock() {
        let blocks = MarkdownRenderer.parse("```python\nprint(1)\n```")
        guard case .codeBlock(let lang, let code) = blocks[0] else {
            XCTFail("应解析出代码块"); return
        }
        XCTAssertEqual(lang, "python")
        XCTAssertTrue(code.contains("print(1)"))
    }

    func testInlineBoldAndLink() {
        let attr = MarkdownRenderer.inline("这是**加粗**和[链接](https://x.com)")
        let str = String(attr.characters)
        XCTAssertTrue(str.contains("加粗"))
        XCTAssertTrue(str.contains("链接"))
    }
}

// MARK: - PipelineWorker body 三级兜底

final class ResolveBodyTests: XCTestCase {
    func testMdPreferred() {
        let body = PipelineWorker.resolveBody(md: "全文 markdown", html: "<p>html</p>", excerpt: "摘要")
        XCTAssertEqual(body, "全文 markdown", "md 非空优先用 md")
    }
    func testHtmlFallback() {
        let body = PipelineWorker.resolveBody(md: nil, html: "<p>正文 <b>加粗</b></p>", excerpt: "摘要")
        XCTAssertFalse(body.contains("<"), "html 兜底要剥标签")
        XCTAssertTrue(body.contains("正文"), "html 兜底保留文本")
    }
    func testExcerptFallback() {
        let body = PipelineWorker.resolveBody(md: nil, html: nil, excerpt: "只有摘要")
        XCTAssertEqual(body, "只有摘要")
    }
    func testAllEmpty() {
        let body = PipelineWorker.resolveBody(md: nil, html: "", excerpt: nil)
        XCTAssertEqual(body, "")
    }
    func testCaptchaPlaceholderFallsBackToExcerpt() {
        let placeholder = """
        ---
        source: https://example.com/article
        ---

        Warning: This page maybe requiring CAPTCHA, please make sure you are authorized to access this page.

        Markdown Content:

        """
        let body = PipelineWorker.resolveBody(md: placeholder, html: nil, excerpt: "真实文章摘要")
        XCTAssertEqual(body, "真实文章摘要")
    }
}

// MARK: - ArticleRow 相对时间

final class RelativeDateTests: XCTestCase {
    func testMinutesAgo() {
        let iso = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-300))
        let r = ArticleRow.relativeDate(from: iso)
        XCTAssertTrue(r.contains("分钟前"), "5 分钟前应显示分钟前，实际: \(r)")
    }
    func testHoursAgo() {
        let iso = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200))
        let r = ArticleRow.relativeDate(from: iso)
        XCTAssertTrue(r.contains("小时前"), "2 小时前应显示小时前，实际: \(r)")
    }
    func testDaysAgo() {
        let iso = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400 * 2))
        let r = ArticleRow.relativeDate(from: iso)
        XCTAssertTrue(r.contains("天前"), "2 天前应显示天前，实际: \(r)")
    }
    func testInvalidFallsBack() {
        let r = ArticleRow.relativeDate(from: "not-a-date")
        XCTAssertFalse(r.isEmpty, "非法日期应回退不崩溃")
    }
}

// MARK: - 音频播放器控制

final class AudioPlaybackControlTests: XCTestCase {
    func testSeekTimeClampsToPlayableRange() {
        XCTAssertEqual(AudioPlaybackSettings.clampedTime(-15, duration: 100), 0)
        XCTAssertEqual(AudioPlaybackSettings.clampedTime(35, duration: 100), 35)
        XCTAssertEqual(AudioPlaybackSettings.clampedTime(130, duration: 100), 100)
        XCTAssertEqual(AudioPlaybackSettings.clampedTime(.infinity, duration: 100), 0)
    }

    func testTimeFormattingSupportsLongPodcasts() {
        XCTAssertEqual(AudioPlayerView.formatTime(65), "1:05")
        XCTAssertEqual(AudioPlayerView.formatTime(3_661), "1:01:01")
        XCTAssertEqual(AudioPlayerView.formatTime(.nan), "0:00")
    }

    func testPlaybackRateLabelsStayExact() {
        XCTAssertEqual(AudioPlayerView.formatRate(0.75), "0.75×")
        XCTAssertEqual(AudioPlayerView.formatRate(1), "1×")
        XCTAssertEqual(AudioPlayerView.formatRate(1.25), "1.25×")
        XCTAssertEqual(AudioPlayerView.formatRate(1.5), "1.5×")
        XCTAssertEqual(AudioPlayerView.formatRate(2), "2×")
    }
}

// MARK: - 列表筛选与跨文章处理状态

final class ContentListFilterTests: XCTestCase {
    func testDefaultScoreRangeDoesNotCreateSQLBounds() {
        let bounds = ContentViewModel.scoreBounds(minimum: 0, maximum: 100)
        XCTAssertNil(bounds.minimum)
        XCTAssertNil(bounds.maximum)
    }

    func testScoreRangeClampsButDoesNotSilentlySwapInvalidInput() {
        let clamped = ContentViewModel.scoreBounds(minimum: -20, maximum: 130)
        XCTAssertNil(clamped.minimum)
        XCTAssertNil(clamped.maximum)

        let invalid = ContentViewModel.scoreBounds(minimum: 90, maximum: 80)
        XCTAssertEqual(invalid.minimum, 90)
        XCTAssertEqual(invalid.maximum, 80)
    }

    @MainActor
    func testProcessingStateSurvivesViewReplacementByContentId() {
        let store = ContentProcessingStateStore.shared
        let first: Int64 = 9_880_001
        let second: Int64 = 9_880_002
        store.clear(contentId: first)
        store.clear(contentId: second)
        defer {
            store.clear(contentId: first)
            store.clear(contentId: second)
        }

        store.begin(contentId: first, message: "翻译中…")
        XCTAssertEqual(store.state(for: first)?.isProcessing, true)
        XCTAssertEqual(store.state(for: first)?.message, "翻译中…")
        XCTAssertNil(store.state(for: second))

        store.finish(contentId: first, message: "✅ 翻译完成")
        XCTAssertEqual(store.state(for: first)?.isProcessing, false)
        XCTAssertEqual(store.state(for: first)?.message, "✅ 翻译完成")
    }
}

// MARK: - 原生可选择链接标题

final class SelectableLinkTitleTests: XCTestCase {
    @MainActor
    func testNativeTitleRemainsSelectableAndWrapsToAvailableWidth() {
        let view = RBSelectableLinkTextView()
        view.configure(
            text: "这是一段足够长、需要随阅读器宽度自动换行的可选择文章标题",
            destination: "https://example.com/article",
            font: .systemFont(ofSize: 24, weight: .bold),
            normalColor: .labelColor,
            hoverColor: .controlAccentColor)

        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.isEditable)
        XCTAssertGreaterThan(view.requiredHeight(for: 180), view.requiredHeight(for: 600))
    }

    @MainActor
    func testNormalMarkdownBlocksShareOneSelectionFlow() {
        let markdown = """
        # 章节标题

        第一段正文。

        第二段正文。

        - 列表一
        - 列表二

        第三段正文。
        """
        XCTAssertEqual(
            MarkdownBodyView.selectionUnitBlockCountsForTesting(markdown: markdown),
            [6])
    }

    @MainActor
    func testVisualCardsRemainSelectionBoundaries() {
        let markdown = """
        第一段。

        > 独立引用卡

        第二段。
        """
        XCTAssertEqual(
            MarkdownBodyView.selectionUnitBlockCountsForTesting(markdown: markdown),
            [1, 1, 1])
    }
}
