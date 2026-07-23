-- 007: 标签系统
-- tag 表 + content_tag 关联（多对多）
CREATE TABLE IF NOT EXISTS tag (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    color       TEXT,                    -- 可选颜色 hex
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS content_tag (
    content_id  INTEGER NOT NULL REFERENCES content(id) ON DELETE CASCADE,
    tag_id      INTEGER NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
    PRIMARY KEY (content_id, tag_id)
);

CREATE INDEX IF NOT EXISTS idx_content_tag_tag ON content_tag (tag_id);
CREATE INDEX IF NOT EXISTS idx_content_tag_content ON content_tag (content_id);
