import XCTest
@testable import ReadBoard

/// 必须配合 READBOARD_DB 指向隔离临时路径运行，验证全新安装能只靠 App 资源建库。
final class DatabaseBootstrapTests: XCTestCase {
    func testFreshDatabaseCreatesCurrentSchema() throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向临时数据库；跳过以免触碰真实库")
        }
        XCTAssertTrue(Database.shared.open())
        XCTAssertEqual(Database.shared.scalarInt("PRAGMA user_version;"), 27)

        let requiredColumns = ["deleted_at", "llm_translated_md", "llm_transcript_md",
                               "first_image_url"]
        let columns = Set(Database.shared.queryRows("PRAGMA table_info(content);")
            .compactMap { $0["name"] })
        for column in requiredColumns {
            XCTAssertTrue(columns.contains(column), "全新数据库缺少字段 \(column)")
        }
        let indexes = Set(Database.shared.queryRows("PRAGMA index_list(content);")
            .compactMap { $0["name"] })
        for index in ["idx_content_worker_score", "idx_content_worker_translate",
                      "idx_content_worker_summarize", "idx_content_worker_transcribe",
                      "idx_content_active_published", "idx_content_active_type_published"] {
            XCTAssertTrue(indexes.contains(index), "全新数据库缺少内容处理索引 \(index)")
        }
        XCTAssertFalse(columns.contains("is_archived"), "归档状态字段应已从当前数据库结构移除")
        XCTAssertEqual(Database.shared.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='content_fts';"), 1)
    }

    func testLightweightListCategoryCountsAndExactMarkReadScope() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sid: Int64 = 9_210_001
        let articleId: Int64 = 9_210_011
        let podcastId: Int64 = 9_210_012
        let videoId: Int64 = 9_210_013
        let ids = [articleId, podcastId, videoId]
        cleanup(ids: ids, sourceIds: [sid])
        defer { cleanup(ids: ids, sourceIds: [sid]) }
        let before = db.libraryCounts()

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id, stype, name, identifier, config, enabled)
            VALUES (?, 'rss', '轻量列表测试源', ?, '{}', 1);
            """, params: [sid, "https://test.invalid/list-source-\(sid)"]))
        let longBody = String(repeating: "正文", count: 300)
        XCTAssertTrue(db.execute("""
            INSERT INTO content
                (id,source_id,ctype,guid,source,title,url,content_md,first_image_url,fetch_status)
            VALUES (?,?,'article',?,'rss','文章',?,?,?,2),
                   (?,?,'podcast',?,'podcast','播客',?,NULL,NULL,0),
                   (?,?,'video',?,'youtube','视频',?,NULL,NULL,0);
            """, params: [articleId, sid, "list-guid-\(articleId)",
                             "https://test.invalid/item/\(articleId)", longBody,
                             "https://test.invalid/image.jpg",
                             podcastId, sid, "list-guid-\(podcastId)",
                             "https://test.invalid/item/\(podcastId)",
                             videoId, sid, "list-guid-\(videoId)",
                             "https://test.invalid/item/\(videoId)"]))

        let counts = db.libraryCounts()
        XCTAssertEqual(counts.total, before.total + 3)
        XCTAssertEqual(counts.articles, before.articles + 1)
        XCTAssertEqual(counts.podcasts, before.podcasts + 1)
        XCTAssertEqual(counts.videos, before.videos + 1)

        let article = try XCTUnwrap(db.fetchContents(sourceId: sid, contentCategory: "article").first)
        XCTAssertEqual(article.id, articleId)
        XCTAssertEqual(article.sourceName, "轻量列表测试源")
        XCTAssertEqual(article.imageUrl, "https://test.invalid/image.jpg")
        XCTAssertTrue(article.hasFulltext)
        XCTAssertEqual(db.fetchContents(sourceId: sid, processedFilters: ["fulltext": 1]).map(\.id),
                       [articleId])

        XCTAssertEqual(db.markAllRead(sourceId: sid, contentCategory: "podcast"), 1)
        XCTAssertEqual(db.scalarInt("SELECT read_at IS NOT NULL FROM content WHERE id=?",
                                    params: [podcastId]), 1)
        XCTAssertEqual(db.scalarInt("SELECT read_at IS NOT NULL FROM content WHERE id=?",
                                    params: [articleId]), 0)
        XCTAssertEqual(db.markAllRead(sourceId: sid, restrictToContentIds: [videoId]), 1)
        XCTAssertEqual(db.scalarInt("SELECT read_at IS NOT NULL FROM content WHERE id=?",
                                    params: [videoId]), 1)
    }

    func testLibraryCountsExposeUnreadExportedContents() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sid: Int64 = 9_212_001
        let unreadId: Int64 = 9_212_011
        let readId: Int64 = 9_212_012
        let ruleId: Int64 = 9_212_021
        cleanup(ids: [unreadId, readId], sourceIds: [sid])
        db.execute("DELETE FROM export_rule WHERE id=?", params: [ruleId])
        defer {
            db.execute("DELETE FROM export_rule WHERE id=?", params: [ruleId])
            cleanup(ids: [unreadId, readId], sourceIds: [sid])
        }
        let before = db.libraryCounts()

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source(id,stype,name,identifier,config,enabled)
            VALUES (?,'rss','export-count-test',?,'{}',1)
            """, params: [sid, "https://test.invalid/export-count-\(sid)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content(id,source_id,ctype,guid,source,title,url,read_at)
            VALUES (?,?,'article',?,'rss','未读导出',?,NULL),
                   (?,?,'article',?,'rss','已读导出',?,'2026-07-29 00:00:00')
            """, params: [unreadId, sid, "export-count-guid-\(unreadId)",
                            "https://test.invalid/item/\(unreadId)",
                            readId, sid, "export-count-guid-\(readId)",
                            "https://test.invalid/item/\(readId)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO export_rule(id,name,enabled,criteria,trigger_on,target,target_config)
            VALUES (?,'导出计数测试',1,'{}','manual','obsidian','{}')
            """, params: [ruleId]))
        XCTAssertTrue(db.execute("""
            INSERT INTO export_record(rule_id,content_id,artifact,revision,status)
            VALUES (?,?,'original',1,'delivered'),
                   (?,?,'original',1,'delivered')
            """, params: [ruleId, unreadId, ruleId, readId]))

        let counts = db.libraryCounts()
        XCTAssertEqual(counts.exported, before.exported + 2)
        XCTAssertEqual(counts.exportedUnread, before.exportedUnread + 1)
    }

    @MainActor
    func testDeletingSourceHardDeletesContentAndRepairsCrossSourceDuplicate() async throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sourceId: Int64 = 9_215_001
        let otherSourceId: Int64 = 9_215_002
        let originalId: Int64 = 9_215_011
        let duplicateId: Int64 = 9_215_012
        let ruleId: Int64 = 9_215_021
        db.execute("DELETE FROM export_rule WHERE id=?", params: [ruleId])
        cleanup(ids: [originalId, duplicateId], sourceIds: [sourceId, otherSourceId])
        defer {
            db.execute("DELETE FROM export_rule WHERE id=?", params: [ruleId])
            cleanup(ids: [originalId, duplicateId], sourceIds: [sourceId, otherSourceId])
        }

        for (sid, name) in [(sourceId, "待删除源"), (otherSourceId, "保留源")] {
            XCTAssertTrue(db.execute("""
                INSERT INTO content_source (id,stype,name,identifier,config,enabled)
                VALUES (?,'rss',?,?, '{}',1);
                """, params: [sid, name, "https://test.invalid/source/\(sid)"]))
        }
        XCTAssertTrue(db.execute("""
            INSERT INTO content
                (id,source_id,ctype,guid,source,title,url,content_hash,is_duplicate,duplicate_of)
            VALUES (?,?,'article',?,'rss','原件',?,'shared-delete-hash',0,NULL),
                   (?,?,'article',?,'rss','跨源副本',?,'shared-delete-hash',1,?);
            """, params: [originalId, sourceId, "delete-guid-\(originalId)",
                             "https://test.invalid/item/\(originalId)", duplicateId, otherSourceId,
                             "delete-guid-\(duplicateId)",
                             "https://test.invalid/item/\(duplicateId)", originalId]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content_job(content_id,jtype,status) VALUES (?,'score',2);
            """, params: [originalId]))
        XCTAssertTrue(db.execute("""
            INSERT INTO export_rule(id,name,enabled,criteria,trigger_on,target,target_config)
            VALUES (?,'删除源测试',1,'{}','manual','obsidian','{}');
            """, params: [ruleId]))
        XCTAssertTrue(db.execute("""
            INSERT INTO export_record(rule_id,content_id,artifact,revision,status)
            VALUES (?,?,'original',1,'delivered');
            """, params: [ruleId, originalId]))

        let removed = await SourceStore.shared.removeSource(id: sourceId)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(db.scalarInt("SELECT COUNT(*) FROM content_source WHERE id=?", params: [sourceId]), 0)
        XCTAssertEqual(db.scalarInt("SELECT COUNT(*) FROM content WHERE id=?", params: [originalId]), 0)
        XCTAssertEqual(db.scalarInt("SELECT COUNT(*) FROM content_job WHERE content_id=?", params: [originalId]), 0)
        XCTAssertEqual(db.scalarInt("SELECT COUNT(*) FROM export_record WHERE content_id=?", params: [originalId]), 0)
        XCTAssertEqual(db.scalarInt("SELECT is_duplicate FROM content WHERE id=?", params: [duplicateId]), 0)
        XCTAssertNil(db.scalarString("SELECT duplicate_of FROM content WHERE id=?", params: [duplicateId]))
    }

    @MainActor
    func testHistoryScanIncludesPreWatermarkAndSkipsDuplicates() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sid: Int64 = 9_200_001
        let originalId: Int64 = 9_200_011
        let duplicateId: Int64 = 9_200_012
        cleanup(ids: [originalId, duplicateId], sourceIds: [sid])
        defer { cleanup(ids: [originalId, duplicateId], sourceIds: [sid]) }

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id, stype, name, identifier, config)
            VALUES (?, 'rss', 'worker-test', ?, '{"auto_score":true}');
            """, params: [sid, "https://test.invalid/worker-\(sid)"]))
        for (id, duplicate) in [(originalId, 0), (duplicateId, 1)] {
            XCTAssertTrue(db.execute("""
                INSERT INTO content (id, source_id, ctype, guid, source, title, url,
                                     content_md, fetch_status, is_duplicate)
                VALUES (?, ?, 'article', ?, 'rss', '历史任务', ?, '可评分正文', 2, ?);
                """, params: [id, sid, "worker-guid-\(id)", "https://test.invalid/item/\(id)", duplicate]))
        }

        let ids = PipelineWorker.shared.pendingTaskIdsForTesting(
            ignoreWatermark: true, onlySourceId: sid)
        XCTAssertEqual(ids, [originalId], "历史扫描应越过水位线，但重复内容不能进入 AI 队列")
    }

    @MainActor
    func testSourcePolicyOnlyNewFreezesExistingItemsAndHistoryChoiceRequeuesThem() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sid: Int64 = 9_230_001
        let nullFlagId: Int64 = 9_230_011
        let oldEnabledId: Int64 = 9_230_012
        let ids = [nullFlagId, oldEnabledId]
        cleanup(ids: ids, sourceIds: [sid])
        defer { cleanup(ids: ids, sourceIds: [sid]) }

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id, stype, name, identifier, config)
            VALUES (?, 'rss', 'source-history-policy-test', ?, '{"auto_translate":false}');
            """, params: [sid, "https://test.invalid/source-history-\(sid)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content (id, source_id, ctype, guid, source, title, url,
                                 content_md, fetch_status, auto_translate)
            VALUES (?, ?, 'article', ?, 'rss', '历史 NULL 标记', ?, '可翻译正文', 2, NULL),
                   (?, ?, 'article', ?, 'rss', '历史开启标记', ?, '可翻译正文', 2, 1);
            """, params: [nullFlagId, sid, "source-history-guid-\(nullFlagId)",
                            "https://test.invalid/item/\(nullFlagId)",
                            oldEnabledId, sid, "source-history-guid-\(oldEnabledId)",
                            "https://test.invalid/item/\(oldEnabledId)"]))

        let store = SourceStore.shared
        store.reload()
        store.setPolicy(id: sid, key: "auto_translate", value: true)

        XCTAssertEqual(db.scalarInt("SELECT json_extract(config, '$.auto_translate') FROM content_source WHERE id=?", params: [sid]), 1)
        XCTAssertEqual(db.scalarInt("SELECT COUNT(*) FROM content WHERE source_id=? AND auto_translate=0", params: [sid]), 2,
                       "开启后尚未确认历史范围时，所有既有条目都应固定为仅新增之外的 0")
        XCTAssertTrue(PipelineWorker.shared.pendingTaskIdsForTesting(
            ignoreWatermark: true, onlySourceId: sid).isEmpty,
                      "选择仅新增的默认状态不能让历史条目回退读取源开关")

        XCTAssertTrue(store.setHistoricalItemsEnabled(sourceId: sid, key: "auto_translate"))
        XCTAssertEqual(db.scalarInt("SELECT COUNT(*) FROM content WHERE source_id=? AND auto_translate=1", params: [sid]), 2)
        XCTAssertEqual(PipelineWorker.shared.pendingTaskIdsForTesting(
            ignoreWatermark: true, onlySourceId: sid), Array(ids.reversed()),
                       "明确选择处理历史后，源下缺少译文的历史条目应按最新优先进入回填队列")
    }

    @MainActor
    func testFolderPolicyUsesTheSameOnlyNewAndHistorySemantics() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let folderId: Int64 = 9_240_001
        let sourceIds: [Int64] = [9_240_011, 9_240_012]
        let contentIds: [Int64] = [9_240_021, 9_240_022]
        cleanup(ids: contentIds, sourceIds: sourceIds)
        db.execute("DELETE FROM folder WHERE id=?", params: [folderId])
        defer {
            cleanup(ids: contentIds, sourceIds: sourceIds)
            db.execute("DELETE FROM folder WHERE id=?", params: [folderId])
        }

        XCTAssertTrue(db.execute("INSERT INTO folder (id,name) VALUES (?,?)",
                                 params: [folderId, "folder-history-policy-test"]))
        for (index, sid) in sourceIds.enumerated() {
            XCTAssertTrue(db.execute("""
                INSERT INTO content_source (id, stype, name, identifier, config, folder_id)
                VALUES (?, 'rss', ?, ?, '{"auto_score":false}', ?);
                """, params: [sid, "folder-source-\(index)",
                                "https://test.invalid/folder-source-\(sid)", folderId]))
            XCTAssertTrue(db.execute("""
                INSERT INTO content (id, source_id, ctype, guid, source, title, url,
                                     content_md, fetch_status, auto_score)
                VALUES (?, ?, 'article', ?, 'rss', '文件夹历史条目', ?, '可评分正文', 2, ?);
                """, params: [contentIds[index], sid, "folder-history-guid-\(contentIds[index])",
                                "https://test.invalid/item/\(contentIds[index])", index == 0 ? nil : 1]))
        }

        let store = SourceStore.shared
        store.reload()
        store.setFolderPolicy(id: folderId, key: "auto_score", value: true)
        XCTAssertEqual(db.scalarInt("SELECT COUNT(*) FROM content WHERE source_id IN (?,?) AND auto_score=0",
                                    params: sourceIds), 2)
        for sid in sourceIds {
            XCTAssertTrue(PipelineWorker.shared.pendingTaskIdsForTesting(
                ignoreWatermark: true, onlySourceId: sid).isEmpty)
        }

        XCTAssertTrue(store.setHistoricalItemsEnabled(folderId: folderId, key: "auto_score"))
        XCTAssertEqual(db.scalarInt("SELECT COUNT(*) FROM content WHERE source_id IN (?,?) AND auto_score=1",
                                    params: sourceIds), 2)
        for (index, sid) in sourceIds.enumerated() {
            XCTAssertEqual(PipelineWorker.shared.pendingTaskIdsForTesting(
                ignoreWatermark: true, onlySourceId: sid), [contentIds[index]])
        }
    }

    @MainActor
    func testChineseMediaSkipsTranslationButKeepsTranscription() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sid: Int64 = 9_250_001
        let declaredChineseId: Int64 = 9_250_011
        let inferredChineseId: Int64 = 9_250_012
        let englishId: Int64 = 9_250_013
        cleanup(ids: [declaredChineseId, inferredChineseId, englishId], sourceIds: [sid])
        defer { cleanup(ids: [declaredChineseId, inferredChineseId, englishId], sourceIds: [sid]) }

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id, stype, name, identifier, config)
            VALUES (?, 'podcast', 'language-worker-test', ?,
                    '{"auto_translate":true,"auto_transcribe":true}');
            """, params: [sid, "https://test.invalid/language-worker-\(sid)"]))

        let rows: [(Int64, String, String?, String)] = [
            (declaredChineseId, "podcast", "zh-CN", "这是一段中文播客简介，内容足够用于可靠判断语言。"),
            (inferredChineseId, "video", nil, "这是中文视频的节目简介，主要讨论科技和商业发展趋势。"),
            (englishId, "podcast", "en-US", "This is an English podcast description with enough text for translation.")
        ]
        for (id, ctype, language, excerpt) in rows {
            XCTAssertTrue(db.execute("""
                INSERT INTO content (id, source_id, ctype, guid, source, title, url,
                                     language, excerpt, meta, fetch_status)
                VALUES (?, ?, ?, ?, 'podcast', '语言任务测试', ?, ?, ?,
                        '{"audio_url":"https://test.invalid/audio.mp3"}', 0);
                """, params: [id, sid, ctype, "language-guid-\(id)",
                                "https://test.invalid/item/\(id)", language, excerpt]))
        }

        let kinds = PipelineWorker.shared.pendingTaskKindsForTesting(
            ignoreWatermark: true, onlySourceId: sid)
        XCTAssertEqual(kinds[declaredChineseId], ["transcribe"])
        XCTAssertEqual(kinds[inferredChineseId], ["transcribe"])
        XCTAssertEqual(kinds[englishId], ["translate", "transcribe"])
    }

    @MainActor
    func testParsedFeedLanguagePersistsIntoContent() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sid: Int64 = 9_260_001
        cleanup(ids: [], sourceIds: [sid])
        defer {
            db.execute("DELETE FROM content WHERE source_id = ?", params: [sid])
            cleanup(ids: [], sourceIds: [sid])
        }

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id, stype, name, identifier, config)
            VALUES (?, 'podcast', 'language-persist-test', ?, '{}');
            """, params: [sid, "https://test.invalid/language-persist-\(sid)"]))
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel><title>中文播客</title><language>zh_CN</language>
          <item><title>中文节目</title><guid>persist-language-guid</guid>
            <link>https://test.invalid/language-item</link>
            <description>这是一段中文播客简介，内容足够用于判断。</description>
            <enclosure url="https://test.invalid/audio.mp3" type="audio/mpeg"/>
          </item>
        </channel></rss>
        """
        let entry = try XCTUnwrap(FeedFetcher.parseFeedForTest(xml: xml)?.entries.first)
        let contentId = try XCTUnwrap(SourceStore.shared.upsertContentForTesting(
            source: "podcast", sourceId: sid, entry: entry))
        XCTAssertEqual(db.scalarString("SELECT language FROM content WHERE id = ?", params: [contentId]),
                       "zh-cn")
    }

    func testTranscriptFieldDrivesExportRenderingAndFilter() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sid: Int64 = 9_300_001
        let translatedOnlyId: Int64 = 9_300_011
        let transcriptId: Int64 = 9_300_012
        cleanup(ids: [translatedOnlyId, transcriptId], sourceIds: [sid])
        defer { cleanup(ids: [translatedOnlyId, transcriptId], sourceIds: [sid]) }

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id, stype, name, identifier, config)
            VALUES (?, 'podcast', 'transcript-test', ?, '{"auto_transcribe":true}');
            """, params: [sid, "https://test.invalid/transcript-\(sid)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content (id, source_id, ctype, guid, source, title, url, excerpt,
                                 fetch_status, llm_translated_md, meta)
            VALUES (?, ?, 'podcast', ?, 'podcast', '只有译文', ?, '节目简介', 4, '简介译文', '{"audio_url":"https://test.invalid/a.mp3"}');
            """, params: [translatedOnlyId, sid, "transcript-guid-\(translatedOnlyId)", "https://test.invalid/item/\(translatedOnlyId)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content (id, source_id, ctype, guid, source, title, url, excerpt,
                                 fetch_status, llm_translated_md, llm_transcript_md, meta)
            VALUES (?, ?, 'podcast', ?, 'podcast', '真正转录', ?, '节目简介', 4,
                    '简介译文', '真正的转录稿', '{"audio_url":"https://test.invalid/b.mp3"}');
            """, params: [transcriptId, sid, "transcript-guid-\(transcriptId)", "https://test.invalid/item/\(transcriptId)"]))

        XCTAssertNil(ExportService.shared.renderForExport(contentId: translatedOnlyId, view: "transcript"))
        let translated = try XCTUnwrap(ExportService.shared.renderForExport(
            contentId: translatedOnlyId, view: "translated"))
        XCTAssertTrue(translated.contains("简介译文"))
        XCTAssertFalse(translated.contains("真正的转录稿"))
        let transcript = try XCTUnwrap(ExportService.shared.renderForExport(
            contentId: transcriptId, view: "transcript"))
        XCTAssertTrue(transcript.contains("真正的转录稿"))
        XCTAssertFalse(transcript.contains("简介译文"))

        let filtered = db.fetchContents(sourceId: sid, processedFilters: ["transcribe": 1])
        XCTAssertEqual(filtered.map(\.id), [transcriptId])
    }

    func testMarkAllReadUsesTheSameStarredAndProcessedScopeAsList() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sid: Int64 = 9_320_001
        let matchingId: Int64 = 9_320_011
        let matchingUnscoredId: Int64 = 9_320_012
        let unstarredId: Int64 = 9_320_013
        let untranslatedId: Int64 = 9_320_014
        let duplicateId: Int64 = 9_320_015
        let aboveRangeId: Int64 = 9_320_016
        let ids = [matchingId, matchingUnscoredId, unstarredId, untranslatedId,
                   duplicateId, aboveRangeId]
        cleanup(ids: ids, sourceIds: [sid])
        defer { cleanup(ids: ids, sourceIds: [sid]) }

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id, stype, name, identifier, config)
            VALUES (?, 'rss', 'mark-all-scope-test', ?, '{}');
            """, params: [sid, "https://test.invalid/mark-all-\(sid)"]))

        let rows: [(Int64, Int?, Int, String?, Int)] = [
            (matchingId, 80, 1, "译文", 0),
            (matchingUnscoredId, nil, 1, "译文", 0),
            (unstarredId, 80, 0, "译文", 0),
            (untranslatedId, 80, 1, nil, 0),
            (duplicateId, 80, 1, "译文", 1),
            (aboveRangeId, 95, 1, "译文", 0)
        ]
        for (id, score, starred, translation, duplicate) in rows {
            XCTAssertTrue(db.execute("""
                INSERT INTO content (id, source_id, ctype, guid, source, title, url,
                                     excerpt, llm_score, llm_translated_md, starred,
                                     is_duplicate, fetch_status)
                VALUES (?, ?, 'article', ?, 'rss', '批量已读范围测试', ?,
                        '测试简介', ?, ?, ?, ?, 2);
                """, params: [id, sid, "mark-all-guid-\(id)",
                                "https://test.invalid/item/\(id)", score, translation,
                                starred, duplicate]))
        }

        let visibleBefore = db.fetchContents(
            sourceId: sid, minScore: 70, maxScore: 90, includeUnscored: true,
            unreadOnly: true, starredOnly: true,
            processedFilters: ["translate": 1])
        XCTAssertEqual(Set(visibleBefore.map(\.id)), Set([matchingId, matchingUnscoredId]))

        let changed = db.markAllRead(
            sourceId: sid, minScore: 70, maxScore: 90, includeUnscored: true,
            starredOnly: true, processedFilters: ["translate": 1])
        XCTAssertEqual(changed, 2)
        XCTAssertEqual(db.scalarInt(
            "SELECT COUNT(*) FROM content WHERE id IN (?, ?) AND read_at IS NOT NULL",
            params: [matchingId, matchingUnscoredId]), 2)
        XCTAssertEqual(db.scalarInt(
            "SELECT COUNT(*) FROM content WHERE id IN (?, ?, ?, ?) AND read_at IS NOT NULL",
            params: [unstarredId, untranslatedId, duplicateId, aboveRangeId]), 0)
    }

    @MainActor
    func testSuccessfulJobWithBlankTranslationStillReturnsToPendingQueue() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sid: Int64 = 9_330_001
        let cid: Int64 = 9_330_011
        cleanup(ids: [cid], sourceIds: [sid])
        defer { cleanup(ids: [cid], sourceIds: [sid]) }

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id, stype, name, identifier, config)
            VALUES (?, 'rss', 'blank-translation-test', ?, '{"auto_translate":true}');
            """, params: [sid, "https://test.invalid/blank-translation-\(sid)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content (id, source_id, ctype, guid, source, title, url,
                                 content_md, llm_translated_md, fetch_status)
            VALUES (?, ?, 'article', ?, 'rss', '空译文测试', ?, '可翻译的完整正文', '  ', 2);
            """, params: [cid, sid, "blank-translation-guid-\(cid)",
                            "https://test.invalid/item/\(cid)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content_job (content_id, jtype, status, finished_at)
            VALUES (?, 'translate', 2, datetime('now'));
            """, params: [cid]))

        let kinds = PipelineWorker.shared.pendingTaskKindsForTesting(
            ignoreWatermark: true, onlySourceId: sid)
        XCTAssertEqual(kinds[cid], ["translate"])
    }

    func testExportRuleUsesSelectedView() async throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let cid: Int64 = 9_350_011
        cleanup(ids: [cid], sourceIds: [])
        defer { cleanup(ids: [cid], sourceIds: []) }

        XCTAssertTrue(db.execute("""
            INSERT INTO content (id, ctype, guid, source, title, url, excerpt,
                                 content_md, llm_translated_md, llm_transcript_md)
            VALUES (?, 'podcast', ?, 'podcast', '导出视图测试', ?, '简介',
                    '只属于原文', '只属于译文', '只属于转录稿');
            """, params: [cid, "export-view-guid-\(cid)", "https://test.invalid/item/\(cid)"]))

        let outputDir = NSTemporaryDirectory() + "readboard-export-view-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: outputDir) }
        let rule = ExportRule(
            id: 0,
            name: "转录稿导出",
            enabled: true,
            criteria: ExportRule.Criteria(),
            triggerOn: "manual",
            target: "mddir",
            targetConfig: ["dir": outputDir, "view": "transcript"],
            lastRunAt: nil)

        let result = await ExportService.shared.deliverSingle(rule: rule, contentId: cid)
        XCTAssertTrue(result.0, result.2 ?? "导出失败")
        let path = try XCTUnwrap(result.1)
        let exported = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(exported.contains("只属于转录稿"))
        XCTAssertFalse(exported.contains("只属于原文"))
        XCTAssertFalse(exported.contains("只属于译文"))
    }

    @MainActor
    func testReadRetentionSoftDeletesOnlyUnprotectedContent() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sid: Int64 = 9_400_001
        let plainId: Int64 = 9_400_011
        let obsoleteMarkerId: Int64 = 9_400_012
        let starredId: Int64 = 9_400_013
        CacheCleanupService.shared.clearAllTrash()
        cleanup(ids: [plainId, obsoleteMarkerId, starredId], sourceIds: [sid])
        defer {
            cleanup(ids: [plainId, obsoleteMarkerId, starredId], sourceIds: [sid])
            CacheCleanupService.shared.clearAllTrash()
        }

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id, stype, name, identifier, config)
            VALUES (?, 'rss', 'retention-test', ?, '{}');
            """, params: [sid, "https://test.invalid/retention-\(sid)"]))
        for (id, starred, meta) in [
            (plainId, 0, "{}"),
            (obsoleteMarkerId, 0, "{\"markdown_saved_at\":\"2026-01-01 00:00:00\"}"),
            (starredId, 1, "{}")
        ] {
            XCTAssertTrue(db.execute("""
                INSERT INTO content (id, source_id, ctype, guid, source, title, url,
                                     content_md, fetch_status, read_at, starred, meta)
                VALUES (?, ?, 'article', ?, 'rss', '保留测试', ?, '正文', 2,
                        '2020-01-01 00:00:00', ?, ?);
                """, params: [id, sid, "retention-guid-\(id)", "https://test.invalid/item/\(id)", starred, meta]))
        }

        let cleanupService = CacheCleanupService.shared
        let oldEnabled = cleanupService.deleteEnabled
        let oldDays = cleanupService.deleteAfterDays
        cleanupService.deleteEnabled = true
        cleanupService.deleteAfterDays = 1
        defer {
            cleanupService.deleteEnabled = oldEnabled
            cleanupService.deleteAfterDays = oldDays
        }

        XCTAssertEqual(cleanupService.runRetention(), 2)
        XCTAssertNotNil(db.scalarString("SELECT deleted_at FROM content WHERE id = ?", params: [plainId]))
        XCTAssertNotNil(db.scalarString("SELECT deleted_at FROM content WHERE id = ?", params: [obsoleteMarkerId]))
        XCTAssertNil(db.scalarString("SELECT deleted_at FROM content WHERE id = ?", params: [starredId]))
    }

    @MainActor
    func testRetentionBacksUpClearsLargeFieldsAndRestoresSoftDeletedRow() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sid: Int64 = 9_410_001
        let cid: Int64 = 9_410_011
        let service = CacheCleanupService.shared
        service.clearAllTrash()
        cleanup(ids: [cid], sourceIds: [sid])
        defer {
            cleanup(ids: [cid], sourceIds: [sid])
            service.clearAllTrash()
        }

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id, stype, name, identifier, config)
            VALUES (?, 'rss', 'retention-restore-test', ?, '{}');
            """, params: [sid, "https://test.invalid/retention-restore-\(sid)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content (
                id, source_id, ctype, guid, source, title, author, url, language,
                published_at, content_html, content_md, excerpt, word_count, reading_minutes,
                fetch_status, fetch_engine, fetch_error, fetched_full_at,
                llm_score, llm_summary, llm_translated_md, llm_excerpt_translated,
                llm_title_translated, llm_transcript_md, llm_model, llm_processed_at,
                read_at, starred, meta
            ) VALUES (
                ?, ?, 'article', ?, 'rss', '待回收内容', '作者', ?, 'en',
                '2020-01-01 00:00:00', '<p>完整 HTML</p>', '# 完整正文', '原始摘要', 321, 2,
                2, 'reader', '抓取错误详情', '2020-01-02 00:00:00',
                87, 'AI 摘要', '# 完整译文', '短译文', '译文标题', '# 完整转录',
                'test-model', '2020-01-03 00:00:00', '2020-01-04 00:00:00', 0,
                '{"audio_url":"https://test.invalid/audio.mp3"}'
            );
            """, params: [cid, sid, "retention-restore-guid-\(cid)", "https://test.invalid/item/\(cid)"]))

        let oldEnabled = service.deleteEnabled
        let oldDays = service.deleteAfterDays
        service.deleteEnabled = true
        service.deleteAfterDays = 1
        defer {
            service.deleteEnabled = oldEnabled
            service.deleteAfterDays = oldDays
        }

        XCTAssertEqual(service.runRetention(), 1)
        XCTAssertNotNil(db.scalarString("SELECT deleted_at FROM content WHERE id = ?", params: [cid]))
        XCTAssertEqual(db.scalarString("SELECT guid FROM content WHERE id = ?", params: [cid]),
                       "retention-restore-guid-\(cid)", "最小元数据必须保留以防重复抓取")
        XCTAssertEqual(db.scalarString("SELECT title FROM content WHERE id = ?", params: [cid]), "待回收内容")
        for field in [
            "content_html", "content_md", "excerpt", "llm_summary", "llm_translated_md",
            "llm_excerpt_translated", "llm_title_translated", "llm_transcript_md", "llm_model",
            "fetch_error"
        ] {
            XCTAssertNil(db.scalarString("SELECT \(field) FROM content WHERE id = ?", params: [cid]),
                         "清理后大字段 \(field) 应释放")
        }

        let batches = service.listTrash()
        let batch = try XCTUnwrap(batches.first(where: { trashBatch in
            guard let text = try? String(contentsOfFile: trashBatch.path, encoding: .utf8) else { return false }
            return text.contains("retention-restore-guid-\(cid)")
        }))
        let jsonl = try String(contentsOfFile: batch.path, encoding: .utf8)
        XCTAssertTrue(jsonl.contains("# 完整正文"))
        XCTAssertTrue(jsonl.contains("# 完整译文"))
        XCTAssertTrue(jsonl.contains("# 完整转录"))

        XCTAssertEqual(service.restoreTrash(batch: batch).restored, 1)
        XCTAssertNil(db.scalarString("SELECT deleted_at FROM content WHERE id = ?", params: [cid]))
        XCTAssertEqual(db.scalarString("SELECT content_html FROM content WHERE id = ?", params: [cid]),
                       "<p>完整 HTML</p>")
        XCTAssertEqual(db.scalarString("SELECT content_md FROM content WHERE id = ?", params: [cid]), "# 完整正文")
        XCTAssertEqual(db.scalarString("SELECT llm_translated_md FROM content WHERE id = ?", params: [cid]),
                       "# 完整译文")
        XCTAssertEqual(db.scalarString("SELECT llm_transcript_md FROM content WHERE id = ?", params: [cid]),
                       "# 完整转录")
        XCTAssertEqual(db.scalarString("SELECT llm_summary FROM content WHERE id = ?", params: [cid]), "AI 摘要")
        XCTAssertEqual(db.scalarInt("SELECT llm_score FROM content WHERE id = ?", params: [cid]), 87)
    }

    @MainActor
    func testRetentionDoesNotClearDatabaseWhenTrashBackupFails() throws {
        try requireIsolatedDatabase()
        let db = Database.shared
        XCTAssertTrue(db.open())
        let sid: Int64 = 9_420_001
        let cid: Int64 = 9_420_011
        let service = CacheCleanupService.shared
        let trashPath = Database.dataDirectory + "/trash"
        service.clearAllTrash()
        XCTAssertTrue(FileManager.default.createFile(atPath: trashPath, contents: Data("blocked".utf8)),
                      "测试需要用普通文件阻断 trash 目录创建")
        cleanup(ids: [cid], sourceIds: [sid])
        defer {
            cleanup(ids: [cid], sourceIds: [sid])
            try? FileManager.default.removeItem(atPath: trashPath)
        }

        XCTAssertTrue(db.execute("""
            INSERT INTO content_source (id, stype, name, identifier, config)
            VALUES (?, 'rss', 'retention-backup-failure-test', ?, '{}');
            """, params: [sid, "https://test.invalid/retention-failure-\(sid)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content (id, source_id, ctype, guid, source, title, url,
                                 content_html, content_md, llm_translated_md, read_at)
            VALUES (?, ?, 'article', ?, 'rss', '备份失败保护', ?, '<p>不能丢</p>',
                    '# 不能丢', '# 译文不能丢', '2020-01-01 00:00:00');
            """, params: [cid, sid, "retention-failure-guid-\(cid)", "https://test.invalid/item/\(cid)"]))

        let oldEnabled = service.deleteEnabled
        let oldDays = service.deleteAfterDays
        service.deleteEnabled = true
        service.deleteAfterDays = 1
        defer {
            service.deleteEnabled = oldEnabled
            service.deleteAfterDays = oldDays
        }

        XCTAssertEqual(service.runRetention(), 0)
        XCTAssertNil(db.scalarString("SELECT deleted_at FROM content WHERE id = ?", params: [cid]))
        XCTAssertEqual(db.scalarString("SELECT content_md FROM content WHERE id = ?", params: [cid]), "# 不能丢")
        XCTAssertEqual(db.scalarString("SELECT llm_translated_md FROM content WHERE id = ?", params: [cid]),
                       "# 译文不能丢")
    }

    private func requireIsolatedDatabase() throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向临时数据库；跳过以免触碰真实库")
        }
    }

    private func cleanup(ids: [Int64], sourceIds: [Int64]) {
        let db = Database.shared
        for id in ids {
            db.execute("DELETE FROM content_job WHERE content_id = ?", params: [id])
            db.execute("DELETE FROM content WHERE id = ?", params: [id])
        }
        for id in sourceIds {
            db.execute("DELETE FROM content_source WHERE id = ?", params: [id])
        }
    }
}
