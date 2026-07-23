-- 010: FTS5 全文搜索索引
-- 给 title/excerpt/content_md 建 FTS5 索引，替代 LIKE 三列全表扫（实测 0.594s → 毫秒级）。
-- 用 content= 外部内容模式，数据不冗余存储，靠触发器与 content 表同步。

CREATE VIRTUAL TABLE IF NOT EXISTS content_fts USING fts5(
    title,
    excerpt,
    content_md,
    content='content',
    content_rowid='id'
);

-- 新插入同步到 FTS
CREATE TRIGGER IF NOT EXISTS content_fts_ai AFTER INSERT ON content BEGIN
    INSERT INTO content_fts(rowid, title, excerpt, content_md)
    VALUES (new.id, new.title, new.excerpt, new.content_md);
END;

-- 删除同步
CREATE TRIGGER IF NOT EXISTS content_fts_ad AFTER DELETE ON content BEGIN
    INSERT INTO content_fts(content_fts, rowid, title, excerpt, content_md)
    VALUES ('delete', old.id, old.title, old.excerpt, old.content_md);
END;

-- 更新同步（正文/标题变化）
CREATE TRIGGER IF NOT EXISTS content_fts_au AFTER UPDATE ON content BEGIN
    INSERT INTO content_fts(content_fts, rowid, title, excerpt, content_md)
    VALUES ('delete', old.id, old.title, old.excerpt, old.content_md);
    INSERT INTO content_fts(rowid, title, excerpt, content_md)
    VALUES (new.id, new.title, new.excerpt, new.content_md);
END;

-- 首次回填已有数据
INSERT INTO content_fts(content_fts) VALUES('rebuild');
