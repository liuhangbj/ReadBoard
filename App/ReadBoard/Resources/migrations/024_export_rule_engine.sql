-- 024: 可版本化的导出规则与交付记录。

ALTER TABLE export_rule ADD COLUMN revision INTEGER NOT NULL DEFAULT 1;
ALTER TABLE export_rule ADD COLUMN artifact TEXT NOT NULL DEFAULT 'original';
ALTER TABLE export_rule ADD COLUMN missing_policy TEXT NOT NULL DEFAULT 'wait';
ALTER TABLE export_rule ADD COLUMN output_format TEXT NOT NULL DEFAULT 'markdown';
ALTER TABLE export_rule ADD COLUMN subfolder_template TEXT NOT NULL DEFAULT '';
ALTER TABLE export_rule ADD COLUMN filename_template TEXT NOT NULL DEFAULT '{title}-{id}';
ALTER TABLE export_rule ADD COLUMN write_policy TEXT NOT NULL DEFAULT 'overwrite';
-- 旧规则维持原来的全量行为；服务层创建的新规则会显式写 new_only。
ALTER TABLE export_rule ADD COLUMN history_scope TEXT NOT NULL DEFAULT 'all';
ALTER TABLE export_rule ADD COLUMN frontmatter_fields TEXT NOT NULL DEFAULT '["title","source","author","url","score","ctype","published","summary","id"]';
ALTER TABLE export_rule ADD COLUMN attachments_policy TEXT NOT NULL DEFAULT 'remote';

UPDATE export_rule
SET trigger_on = 'ready'
WHERE trigger_on IN ('score', 'translate', 'transcribe');

UPDATE export_rule
SET artifact = CASE
    WHEN json_extract(target_config, '$.view') IN
         ('original','translated','transcript','summary','summary_original',
          'summary_translated','summary_transcript','bilingual')
    THEN json_extract(target_config, '$.view')
    ELSE 'original'
END,
subfolder_template = COALESCE(json_extract(target_config, '$.subfolder'), ''),
write_policy = CASE
    WHEN json_extract(target_config, '$.overwrite') = 0 THEN 'versioned'
    ELSE 'overwrite'
END;

ALTER TABLE export_record RENAME TO export_record_v23;

CREATE TABLE export_record (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_id       INTEGER NOT NULL REFERENCES export_rule(id) ON DELETE CASCADE,
    content_id    INTEGER NOT NULL,
    artifact      TEXT NOT NULL DEFAULT 'original',
    revision      INTEGER NOT NULL DEFAULT 1,
    status        TEXT NOT NULL,
    destination   TEXT,
    error         TEXT,
    rendered_hash TEXT,
    attempts      INTEGER NOT NULL DEFAULT 0,
    created_at    TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at    TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (rule_id, content_id, artifact, revision)
);

INSERT INTO export_record
    (id, rule_id, content_id, artifact, revision, status, destination, error,
     rendered_hash, attempts, created_at, updated_at)
SELECT old_record.id, old_record.rule_id, old_record.content_id, 'original', 1,
       old_record.status, old_record.destination, old_record.error,
       NULL, CASE WHEN old_record.status = 'delivered' THEN 1 ELSE 0 END,
       old_record.created_at, old_record.created_at
FROM export_record_v23 old_record
JOIN export_rule live_rule ON live_rule.id = old_record.rule_id;

DROP TABLE export_record_v23;

CREATE INDEX IF NOT EXISTS idx_export_record_rule
ON export_record (rule_id, revision, artifact, status);
