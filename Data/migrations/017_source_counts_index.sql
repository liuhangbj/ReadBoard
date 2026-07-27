-- 017: 侧栏计数覆盖索引
-- fetchSidebarTree 原来对每个源跑两条相关子查询 COUNT(*)（302 源 × 2 = 604 次全表扫），
-- 且 content 表带 content_html 大字段、无任何覆盖索引 → 单次 sidebarTree 1.7s，
-- 而 reload() 每次筛选/切换都调它 → 切文件夹/订阅源必转风火轮（17:18 实测定位）。
-- 覆盖索引让聚合只扫索引页（不碰含 HTML 的表页），聚合查询 1.7s → ~20ms。
CREATE INDEX IF NOT EXISTS idx_content_counts
    ON content(source_id, is_duplicate, is_archived, read_at);
