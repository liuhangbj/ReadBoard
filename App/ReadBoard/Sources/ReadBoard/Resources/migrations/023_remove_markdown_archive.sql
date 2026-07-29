-- 023: 删除自动 Markdown 归档功能。
-- 历史归档标记不再参与阅读、清理或导出；旧的归档触发规则回退为手动执行。

UPDATE content
SET meta = json_remove(COALESCE(meta, '{}'), '$.markdown_saved_at', '$.archived_at')
WHERE json_type(meta, '$.markdown_saved_at') IS NOT NULL
   OR json_type(meta, '$.archived_at') IS NOT NULL;

UPDATE export_rule
SET trigger_on = 'manual'
WHERE trigger_on IN ('archive', 'markdown');
