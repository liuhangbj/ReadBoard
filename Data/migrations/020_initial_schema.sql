-- ReadBoard SQLite 初始结构 v20
--
-- 这是全新安装的唯一建库基线，直接创建当前最终结构。
-- 开发期 001-020 的增量脚本已合并，不再重放历史字段交换或数据修复。
-- 已有 v20 数据库会按 PRAGMA user_version 跳过本文件；后续结构变更从 021 开始。

-- 文件夹
CREATE TABLE IF NOT EXISTS folder (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL UNIQUE,
    config     TEXT    NOT NULL DEFAULT '{}',
    created_at TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- 订阅源
CREATE TABLE IF NOT EXISTS content_source (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    stype           TEXT    NOT NULL,
    name            TEXT    NOT NULL,
    identifier      TEXT    NOT NULL,
    config          TEXT    NOT NULL DEFAULT '{}',
    feed_id         INTEGER,
    folder_id       INTEGER REFERENCES folder(id) ON DELETE SET NULL,
    enabled         INTEGER NOT NULL DEFAULT 1,
    last_fetched_at TEXT,
    error           TEXT,
    created_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    UNIQUE (stype, identifier)
);

-- 内容主表
CREATE TABLE IF NOT EXISTS content (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id              INTEGER,
    feed_id               INTEGER,
    source_id             INTEGER REFERENCES content_source(id) ON DELETE SET NULL,
    ctype                 TEXT    NOT NULL DEFAULT 'article',
    guid                  TEXT    NOT NULL,
    source                TEXT    NOT NULL DEFAULT 'rss',
    title                 TEXT    NOT NULL,
    author                TEXT,
    url                   TEXT    NOT NULL,
    language              TEXT,
    published_at          TEXT,
    fetched_at            TEXT    NOT NULL DEFAULT (datetime('now')),
    content_html          TEXT,
    content_md            TEXT,
    excerpt               TEXT,
    word_count            INTEGER,
    reading_minutes       INTEGER,
    fetch_status          INTEGER NOT NULL DEFAULT 0,
    fetch_engine          TEXT,
    fetch_error           TEXT,
    fetched_full_at       TEXT,
    llm_score             INTEGER,
    llm_summary           TEXT,
    llm_translated_md     TEXT,
    llm_excerpt_translated TEXT,
    llm_title_translated  TEXT,
    llm_transcript_md     TEXT,
    llm_model             TEXT,
    llm_processed_at      TEXT,
    content_hash          TEXT,
    is_duplicate          INTEGER NOT NULL DEFAULT 0,
    duplicate_of          INTEGER,
    read_at               TEXT,
    starred               INTEGER NOT NULL DEFAULT 0,
    is_archived           INTEGER NOT NULL DEFAULT 0,
    deleted_at            TEXT,
    meta                  TEXT    NOT NULL DEFAULT '{}',
    created_at            TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at            TEXT    NOT NULL DEFAULT (datetime('now')),
    UNIQUE (source, guid)
);

-- 内容处理记录
CREATE TABLE IF NOT EXISTS content_job (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    content_id   INTEGER NOT NULL REFERENCES content(id) ON DELETE CASCADE,
    jtype        TEXT    NOT NULL,
    status       INTEGER NOT NULL DEFAULT 0,
    priority     INTEGER NOT NULL DEFAULT 10,
    attempts     INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 3,
    payload      TEXT    NOT NULL DEFAULT '{}',
    result       TEXT,
    error        TEXT,
    run_after    TEXT    NOT NULL DEFAULT (datetime('now')),
    started_at   TEXT,
    finished_at  TEXT,
    created_at   TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- 分类策略
CREATE TABLE IF NOT EXISTS category_policy (
    category_id     INTEGER PRIMARY KEY,
    auto_fetch      INTEGER NOT NULL DEFAULT 1,
    auto_translate  INTEGER NOT NULL DEFAULT 0,
    auto_score      INTEGER NOT NULL DEFAULT 0,
    min_score_keep  INTEGER NOT NULL DEFAULT 0
);

-- 标签
CREATE TABLE IF NOT EXISTS tag (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    color       TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS content_tag (
    content_id  INTEGER NOT NULL REFERENCES content(id) ON DELETE CASCADE,
    tag_id      INTEGER NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
    PRIMARY KEY (content_id, tag_id)
);

-- 自动过滤规则
CREATE TABLE IF NOT EXISTS filter_rule (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL,
    field       TEXT NOT NULL DEFAULT 'title',
    match_type  TEXT NOT NULL DEFAULT 'contains',
    pattern     TEXT NOT NULL,
    action      TEXT NOT NULL,
    source_id   INTEGER REFERENCES content_source(id) ON DELETE CASCADE,
    enabled     INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

-- 导出规则与交付记录
CREATE TABLE IF NOT EXISTS export_rule (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    name          TEXT NOT NULL,
    enabled       INTEGER NOT NULL DEFAULT 1,
    criteria      TEXT NOT NULL DEFAULT '{}',
    trigger_on    TEXT NOT NULL DEFAULT 'manual',
    target        TEXT NOT NULL,
    target_config TEXT NOT NULL DEFAULT '{}',
    created_at    TEXT NOT NULL DEFAULT (datetime('now')),
    last_run_at   TEXT
);

CREATE TABLE IF NOT EXISTS export_record (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_id      INTEGER NOT NULL REFERENCES export_rule(id) ON DELETE CASCADE,
    content_id   INTEGER NOT NULL,
    status       TEXT NOT NULL,
    destination  TEXT,
    error        TEXT,
    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (rule_id, content_id)
);

-- 内容索引
CREATE INDEX IF NOT EXISTS idx_content_ctype
    ON content (ctype);
CREATE INDEX IF NOT EXISTS idx_content_feed
    ON content (feed_id);
CREATE INDEX IF NOT EXISTS idx_content_fetch
    ON content (fetch_status) WHERE fetch_status IN (0, 3);
CREATE INDEX IF NOT EXISTS idx_content_published
    ON content (published_at DESC);
CREATE INDEX IF NOT EXISTS idx_content_score
    ON content (llm_score DESC) WHERE llm_score IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_content_hash
    ON content (content_hash) WHERE content_hash IS NOT NULL AND is_duplicate = 0;
CREATE INDEX IF NOT EXISTS idx_content_sourceid
    ON content (source_id);
CREATE INDEX IF NOT EXISTS idx_content_read
    ON content (read_at);
CREATE INDEX IF NOT EXISTS idx_content_starred
    ON content (starred) WHERE starred = 1;
CREATE INDEX IF NOT EXISTS idx_content_counts
    ON content (source_id, is_duplicate, is_archived, read_at);

-- 其他索引
CREATE INDEX IF NOT EXISTS idx_source_folder
    ON content_source (folder_id);
CREATE INDEX IF NOT EXISTS idx_job_content
    ON content_job (content_id);
CREATE INDEX IF NOT EXISTS idx_job_claim
    ON content_job (jtype, status, run_after);
CREATE INDEX IF NOT EXISTS idx_content_job_content_jtype
    ON content_job (content_id, jtype, id);
CREATE INDEX IF NOT EXISTS idx_content_tag_tag
    ON content_tag (tag_id);
CREATE INDEX IF NOT EXISTS idx_content_tag_content
    ON content_tag (content_id);
CREATE INDEX IF NOT EXISTS idx_filter_rule_enabled
    ON filter_rule (enabled);
CREATE INDEX IF NOT EXISTS idx_export_record_rule
    ON export_record (rule_id, status);

-- FTS5 全文搜索（外部内容模式）
CREATE VIRTUAL TABLE IF NOT EXISTS content_fts USING fts5(
    title,
    excerpt,
    content_md,
    content='content',
    content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS content_fts_ai AFTER INSERT ON content BEGIN
    INSERT INTO content_fts(rowid, title, excerpt, content_md)
    VALUES (new.id, new.title, new.excerpt, new.content_md);
END;

CREATE TRIGGER IF NOT EXISTS content_fts_ad AFTER DELETE ON content BEGIN
    INSERT INTO content_fts(content_fts, rowid, title, excerpt, content_md)
    VALUES ('delete', old.id, old.title, old.excerpt, old.content_md);
END;

-- 只在 FTS 三列实际出现在 UPDATE 语句中时同步。
-- content_touch 会再发一条仅更新 updated_at 的 UPDATE；若这里监听所有 UPDATE，
-- 两个 AFTER 触发器会交错执行两次 FTS delete/insert，正文从 NULL 首次写入时会报
-- "database disk image is malformed" 并回滚整次正文写入。
CREATE TRIGGER IF NOT EXISTS content_fts_au
AFTER UPDATE OF title, excerpt, content_md ON content BEGIN
    INSERT INTO content_fts(content_fts, rowid, title, excerpt, content_md)
    VALUES ('delete', old.id, old.title, old.excerpt, old.content_md);
    INSERT INTO content_fts(rowid, title, excerpt, content_md)
    VALUES (new.id, new.title, new.excerpt, new.content_md);
END;

-- 自动维护内容更新时间
CREATE TRIGGER IF NOT EXISTS content_touch
AFTER UPDATE ON content
FOR EACH ROW
BEGIN
    UPDATE content SET updated_at = datetime('now') WHERE id = NEW.id;
END;
