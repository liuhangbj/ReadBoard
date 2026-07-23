-- 006: 星标/收藏
-- content 加 starred（0/1），is_archived schema 已存在（FreshRSS 迁移带来）
ALTER TABLE content ADD COLUMN starred INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_content_starred ON content (starred) WHERE starred = 1;
