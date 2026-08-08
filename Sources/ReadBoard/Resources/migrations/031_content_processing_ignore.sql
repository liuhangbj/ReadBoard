-- 用户确认某个内容工序无需再自动补齐后，永久排除该“内容 × 工序”目标。
-- 手动处理入口不读取此表，因此仍可随时手动重做。
CREATE TABLE IF NOT EXISTS content_processing_ignore (
    content_id INTEGER NOT NULL REFERENCES content(id) ON DELETE CASCADE,
    jtype      TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (content_id, jtype)
);

CREATE INDEX IF NOT EXISTS idx_content_processing_ignore_type
    ON content_processing_ignore (jtype, content_id);
