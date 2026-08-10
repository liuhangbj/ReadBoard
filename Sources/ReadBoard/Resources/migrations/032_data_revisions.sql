-- 远程 Reader 用单调版本判断哪些数据域发生变化，避免依赖秒级时间戳。
CREATE TABLE IF NOT EXISTS data_revision (
    domain   TEXT PRIMARY KEY,
    revision INTEGER NOT NULL DEFAULT 0
);

INSERT OR IGNORE INTO data_revision(domain, revision) VALUES
    ('library', 1), ('sources', 1), ('operations', 1);

CREATE TRIGGER IF NOT EXISTS revision_content_insert AFTER INSERT ON content BEGIN
    UPDATE data_revision SET revision = revision + 1 WHERE domain IN ('library','operations');
END;
CREATE TRIGGER IF NOT EXISTS revision_content_update AFTER UPDATE ON content BEGIN
    UPDATE data_revision SET revision = revision + 1 WHERE domain IN ('library','operations');
END;
CREATE TRIGGER IF NOT EXISTS revision_content_delete AFTER DELETE ON content BEGIN
    UPDATE data_revision SET revision = revision + 1 WHERE domain IN ('library','operations');
END;

CREATE TRIGGER IF NOT EXISTS revision_source_insert AFTER INSERT ON content_source BEGIN
    UPDATE data_revision SET revision = revision + 1 WHERE domain IN ('library','sources','operations');
END;
CREATE TRIGGER IF NOT EXISTS revision_source_update AFTER UPDATE ON content_source BEGIN
    UPDATE data_revision SET revision = revision + 1 WHERE domain IN ('library','sources','operations');
END;
CREATE TRIGGER IF NOT EXISTS revision_source_delete AFTER DELETE ON content_source BEGIN
    UPDATE data_revision SET revision = revision + 1 WHERE domain IN ('library','sources','operations');
END;

CREATE TRIGGER IF NOT EXISTS revision_folder_insert AFTER INSERT ON folder BEGIN
    UPDATE data_revision SET revision = revision + 1 WHERE domain IN ('library','sources');
END;
CREATE TRIGGER IF NOT EXISTS revision_folder_update AFTER UPDATE ON folder BEGIN
    UPDATE data_revision SET revision = revision + 1 WHERE domain IN ('library','sources');
END;
CREATE TRIGGER IF NOT EXISTS revision_folder_delete AFTER DELETE ON folder BEGIN
    UPDATE data_revision SET revision = revision + 1 WHERE domain IN ('library','sources');
END;

CREATE TRIGGER IF NOT EXISTS revision_job_insert AFTER INSERT ON content_job BEGIN
    UPDATE data_revision SET revision = revision + 1 WHERE domain = 'operations';
END;
CREATE TRIGGER IF NOT EXISTS revision_job_update AFTER UPDATE ON content_job BEGIN
    UPDATE data_revision SET revision = revision + 1 WHERE domain IN ('library','operations');
END;
CREATE TRIGGER IF NOT EXISTS revision_job_delete AFTER DELETE ON content_job BEGIN
    UPDATE data_revision SET revision = revision + 1 WHERE domain = 'operations';
END;

CREATE TRIGGER IF NOT EXISTS revision_export_insert AFTER INSERT ON export_record BEGIN
    UPDATE data_revision SET revision = revision + 1 WHERE domain IN ('library','operations');
END;
CREATE TRIGGER IF NOT EXISTS revision_export_update AFTER UPDATE ON export_record BEGIN
    UPDATE data_revision SET revision = revision + 1 WHERE domain IN ('library','operations');
END;
CREATE TRIGGER IF NOT EXISTS revision_export_delete AFTER DELETE ON export_record BEGIN
    UPDATE data_revision SET revision = revision + 1 WHERE domain IN ('library','operations');
END;
