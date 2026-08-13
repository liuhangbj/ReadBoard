-- 035: 非订阅收件箱。
-- source_id 继续表示真实订阅源外键；零散链接不伪造 content_source，使用
-- ingest_origin 明确其入库身份，ctype 继续复用文章/播客/视频分类。

ALTER TABLE content
ADD COLUMN ingest_origin TEXT NOT NULL DEFAULT 'subscription';

ALTER TABLE content
ADD COLUMN ingest_request_id TEXT;

CREATE INDEX IF NOT EXISTS idx_content_inbox
ON content (ingest_origin, ctype, published_at DESC, id DESC)
WHERE is_duplicate = 0 AND deleted_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_content_inbox_request
ON content (ingest_request_id)
WHERE ingest_request_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_content_inbox_url
ON content (url)
WHERE ingest_origin = 'inbox' AND is_duplicate = 0 AND deleted_at IS NULL;

DROP TRIGGER IF EXISTS export_ready_content_changed;

CREATE TRIGGER export_ready_content_changed
AFTER UPDATE OF
    source_id, ctype, source, title, author, url, language, published_at,
    content_md, excerpt, llm_score, llm_summary, llm_translated_md,
    llm_title_translated, llm_transcript_md, is_duplicate, read_at, starred,
    deleted_at, visibility_state, ingest_origin
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
