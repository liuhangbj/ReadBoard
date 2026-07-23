-- 011: content_hash 部分唯一索引（R3 去重原子化兜底）
-- 只约束"从今往后"：同一 content_hash 只允许一条主记录(is_duplicate=0)。
-- 存量不管：57k 条 content_hash 为 NULL 的历史记录不参与此约束，保持原样不动。
-- 重复的从记录 is_duplicate=1 不在索引内，可正常插入并被标记。

CREATE UNIQUE INDEX IF NOT EXISTS idx_content_hash_primary
ON content(content_hash)
WHERE is_duplicate = 0 AND content_hash IS NOT NULL;
