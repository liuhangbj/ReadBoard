-- 005: 已读/未读
-- content 加 read_at（NULL = 未读，有时间戳 = 已读）
-- 幂等：SQLite 无 IF NOT EXISTS for column，用应用层判重；此处直接 ALTER，重复执行会报错需忽略

ALTER TABLE content ADD COLUMN read_at TEXT;
CREATE INDEX IF NOT EXISTS idx_content_read ON content (read_at);
