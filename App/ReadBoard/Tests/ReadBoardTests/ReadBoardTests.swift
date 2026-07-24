import XCTest
@testable import ReadBoard

// MARK: - 纯逻辑单元测试（不触网、不触库——触库的走集成测试）

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

final class KeychainTests: XCTestCase {

    /// Keychain 在某些运行环境（WorkBuddy 沙箱/CI）会被 OS 拦（errSecInteractionNotAllowed /
    /// 100001 Operation not permitted）——这不是代码问题，是环境权限。
    /// 测试只验证：调用不崩溃、状态码可读、能区分成功/失败。
    func testSaveLoadDelete() {
        let key = "test.readboard.xctest"
        let status = KeychainHelper.saveWithStatus("secret-token-123", forKey: key)
        if status != errSecSuccess {
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "?"
            // 环境拦截：跳过而非失败（记录以便诊断）
            print("⏭ Keychain 不可用（\(status) \(msg)），跳过读写断言")
            return
        }
        XCTAssertEqual(KeychainHelper.load(forKey: key), "secret-token-123")
        XCTAssertTrue(KeychainHelper.exists(forKey: key))
        KeychainHelper.delete(forKey: key)
        XCTAssertNil(KeychainHelper.load(forKey: key))
        XCTAssertFalse(KeychainHelper.exists(forKey: key))
    }

    func testOverwrite() {
        let key = "test.readboard.overwrite"
        guard KeychainHelper.saveWithStatus("v1", forKey: key) == errSecSuccess else {
            print("⏭ Keychain 不可用，跳过覆盖断言")
            return
        }
        _ = KeychainHelper.save("v2", forKey: key)
        XCTAssertEqual(KeychainHelper.load(forKey: key), "v2")
        KeychainHelper.delete(forKey: key)
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
}
