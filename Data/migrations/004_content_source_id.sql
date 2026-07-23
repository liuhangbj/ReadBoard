-- readboard schema v4: content 关联具体源
-- content.source_id 指向 content_source.id, 让 worker 能按"具体源"精确查开关(替代按 stype 大类归组)
-- 存量数据 source_id 为 NULL(水位线已挡住不处理, 无影响)

ALTER TABLE content ADD COLUMN source_id INTEGER REFERENCES content_source(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_content_sourceid ON content (source_id);
