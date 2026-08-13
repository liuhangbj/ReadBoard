-- 034: 区分“已经进入资料库”和“只有元数据、仍在等待正文”的条目。
--
-- 外部平台有时只返回标题和链接。这样的条目需要保留在数据库中继续重试，
-- 但在正文成功前不应出现在阅读列表、计数或导出候选中。

ALTER TABLE content
ADD COLUMN visibility_state TEXT NOT NULL DEFAULT 'visible';

CREATE INDEX IF NOT EXISTS idx_content_visibility_state
ON content (visibility_state, source_id, published_at DESC, id DESC)
WHERE is_duplicate = 0 AND deleted_at IS NULL;

-- 回填已经存在的微信公众号空壳。保留记录与失败信息供后台重试和问题中心使用，
-- 同时把历史上误留的“直入”状态校正成正文失败。
UPDATE content
SET visibility_state = 'awaiting_content',
    fetch_status = 3,
    fetch_engine = CASE
        WHEN fetch_engine = 'external_fulltext' THEN 'wechat_connector'
        ELSE fetch_engine
    END
WHERE source = 'wechat'
  AND deleted_at IS NULL
  AND LENGTH(TRIM(COALESCE(content_html, ''))) = 0
  AND LENGTH(TRIM(COALESCE(content_md, ''))) = 0
  AND LENGTH(TRIM(COALESCE(excerpt, ''))) = 0
  AND LENGTH(TRIM(COALESCE(fetch_error, ''))) > 0;

-- 可见性变化也会改变 ready 规则是否允许交付，因此把它纳入持久化事件。
DROP TRIGGER IF EXISTS export_ready_content_changed;

CREATE TRIGGER export_ready_content_changed
AFTER UPDATE OF
    source_id, ctype, source, title, author, url, language, published_at,
    content_md, excerpt, llm_score, llm_summary, llm_translated_md,
    llm_title_translated, llm_transcript_md, is_duplicate, read_at, starred,
    deleted_at, visibility_state
ON content
BEGIN
    INSERT INTO export_ready_queue
        (content_id, generation, attempts, available_at, last_error, created_at, updated_at)
    VALUES
        (NEW.id, 1, 0, datetime('now'), NULL, datetime('now'), datetime('now'))
    ON CONFLICT(content_id) DO UPDATE SET
        generation = export_ready_queue.generation + 1,
        attempts = 0,
        available_at = datetime('now'),
        last_error = NULL,
        updated_at = datetime('now');
END;
