-- 021: 修复 FTS 更新触发器与 content_touch 的交错执行。
--
-- 旧 content_fts_au 监听任意 UPDATE；content_touch 又会为每次更新补写 updated_at。
-- 两个 AFTER UPDATE 触发器交错时，FTS delete/insert 会执行两遍，正文从 NULL
-- 首次写入时可能报 "database disk image is malformed"，使全文写入整体回滚。

DROP TRIGGER IF EXISTS content_fts_au;

CREATE TRIGGER content_fts_au
AFTER UPDATE OF title, excerpt, content_md ON content
BEGIN
    INSERT INTO content_fts(content_fts, rowid, title, excerpt, content_md)
    VALUES ('delete', old.id, old.title, old.excerpt, old.content_md);
    INSERT INTO content_fts(rowid, title, excerpt, content_md)
    VALUES (new.id, new.title, new.excerpt, new.content_md);
END;
