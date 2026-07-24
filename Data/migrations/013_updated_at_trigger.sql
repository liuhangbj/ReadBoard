-- 013: 自动维护 content.updated_at
-- 之前 updated_at 只有 INSERT 默认值，任何 UPDATE 都不刷新它，
-- 导致 retention（archive/delete）实际按"创建时间"清理：
-- 老文章被翻出读一遍后仍会被立即归档/删除。
-- 用触发器在任何 UPDATE 时刷新 updated_at（read_at/starred 等状态变化也会刷新，
-- 语义正确：这些字段代表"用户最近一次触碰"，正是 retention 想要的时间基准）。
CREATE TRIGGER IF NOT EXISTS content_touch
AFTER UPDATE ON content
FOR EACH ROW
BEGIN
    UPDATE content SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- 防递归：SQLite 默认 recursive_triggers=OFF，上面的 UPDATE 不会再次触发本触发器，安全。

-- content_job 复合索引：worker 每轮按 content_id+jtype 聚合失败记录，
-- 单列索引下 2000 条内容 × 4 管线是全表扫级别；复合索引让 IN 查询走索引。
CREATE INDEX IF NOT EXISTS idx_content_job_content_jtype
ON content_job (content_id, jtype, id);
