-- 008: 规则过滤器
-- 关键词/正则规则：命中的内容自动执行动作（归档/标已读/加星/打标签）
CREATE TABLE IF NOT EXISTS filter_rule (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL,
    field       TEXT NOT NULL DEFAULT 'title',   -- title / content / author / url
    match_type  TEXT NOT NULL DEFAULT 'contains',-- contains / regex / prefix
    pattern     TEXT NOT NULL,
    action      TEXT NOT NULL,                    -- archive / mark_read / star / tag:<名>
    source_id   INTEGER REFERENCES content_source(id) ON DELETE CASCADE,  -- NULL=全局
    enabled     INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_filter_rule_enabled ON filter_rule (enabled);
