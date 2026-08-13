-- 033: 持久化“内容已变化，需重新评估 ready 导出”的事件。
--
-- generation 防止 Worker 处理期间发生的新变化被旧任务的完成删除；
-- 队列只记录事实，不通过定时扫描推断内容是否变化。

CREATE TABLE IF NOT EXISTS export_ready_queue (
    content_id    INTEGER PRIMARY KEY REFERENCES content(id) ON DELETE CASCADE,
    generation    INTEGER NOT NULL DEFAULT 1,
    attempts      INTEGER NOT NULL DEFAULT 0,
    available_at  TEXT NOT NULL DEFAULT (datetime('now')),
    last_error    TEXT,
    created_at    TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_export_ready_queue_due
ON export_ready_queue (available_at, content_id);

-- 这里只监听会改变导出正文、文件名、frontmatter 或规则匹配结果的字段。
-- 每次真实写库都原子地产生/刷新事件，失败重试和未来新增的处理入口不会再漏掉 ready。
CREATE TRIGGER IF NOT EXISTS export_ready_content_changed
AFTER UPDATE OF
    source_id, ctype, source, title, author, url, language, published_at,
    content_md, excerpt, llm_score, llm_summary, llm_translated_md,
    llm_title_translated, llm_transcript_md, is_duplicate, read_at, starred, deleted_at
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
