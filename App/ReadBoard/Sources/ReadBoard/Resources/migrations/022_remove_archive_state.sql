-- 022: 删除 RSS 内容的“归档”状态。
-- 已归档内容不删除；移除字段后会重新出现在普通文章列表中。
-- Markdown 落盘状态改用明确的 markdown_saved_at，与列表状态彻底解耦。

UPDATE content
SET meta = json_remove(
    json_set(
        COALESCE(meta, '{}'),
        '$.markdown_saved_at',
        json_extract(meta, '$.archived_at')
    ),
    '$.archived_at'
)
WHERE json_type(meta, '$.archived_at') IS NOT NULL;

UPDATE export_rule SET trigger_on = 'markdown' WHERE trigger_on = 'archive';
DELETE FROM filter_rule WHERE action = 'archive';

DROP INDEX IF EXISTS idx_content_counts;
ALTER TABLE content DROP COLUMN is_archived;

CREATE INDEX IF NOT EXISTS idx_content_counts
ON content (source_id, is_duplicate, deleted_at, read_at);
