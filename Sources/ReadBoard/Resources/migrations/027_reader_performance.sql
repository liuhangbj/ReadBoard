-- 阅读列表性能：缓存首图地址，避免每次加载 300 条时搬运并正则扫描完整 HTML。
ALTER TABLE content ADD COLUMN first_image_url TEXT;

-- 为现有内容做一次兼容回填。只检查第一段 <img ...>，规则与旧版“取首个 img src”一致。
WITH image_html AS (
    SELECT id,
           substr(content_html, instr(lower(content_html), '<img')) AS img
    FROM content
    WHERE content_html IS NOT NULL
      AND instr(lower(content_html), '<img') > 0
), positions AS (
    SELECT id, img,
           instr(lower(img), 'src="') AS double_quote_pos,
           instr(lower(img), 'src=''') AS single_quote_pos
    FROM image_html
)
UPDATE content
SET first_image_url = (
    SELECT CASE
        WHEN double_quote_pos > 0 THEN
            substr(img,
                   double_quote_pos + 5,
                   instr(substr(img, double_quote_pos + 5), '"') - 1)
        WHEN single_quote_pos > 0 THEN
            substr(img,
                   single_quote_pos + 5,
                   instr(substr(img, single_quote_pos + 5), '''') - 1)
        ELSE NULL
    END
    FROM positions
    WHERE positions.id = content.id
)
WHERE id IN (SELECT id FROM positions);

-- 活跃内容列表和类型筛选只扫描仍可见的内容。
CREATE INDEX IF NOT EXISTS idx_content_active_published
    ON content (published_at DESC, id DESC)
    WHERE is_duplicate = 0 AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_content_active_type_published
    ON content (ctype, published_at DESC, id DESC)
    WHERE is_duplicate = 0 AND deleted_at IS NULL;

-- 中栏“已导出”标签与筛选按 content_id 查询，旧索引以 rule_id 开头无法命中。
CREATE INDEX IF NOT EXISTS idx_export_record_content_status
    ON export_record (content_id, status);

ANALYZE;
