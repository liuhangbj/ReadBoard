-- readboard SQLite schema v1
-- 从 FreshRSS PostgreSQL (liuhangbj_content*) 迁移而来，去除对 FreshRSS 原生表的 FK 依赖
-- 类型映射: bytea→BLOB, jsonb→TEXT(JSON), timestamptz→TEXT(ISO8601), identity→INTEGER PK, tsvector 弃用

-- ============================================================
-- 内容主表：统一收纳文章/播客/视频/（将来）公众号
-- ============================================================
CREATE TABLE IF NOT EXISTS content (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id        INTEGER,              -- 原 FreshRSS entry.id，仅作历史溯源，独立后新数据为 NULL
    feed_id         INTEGER,              -- 原 FreshRSS feed.id，历史溯源用
    ctype           TEXT    NOT NULL DEFAULT 'article',   -- article / podcast / video
    guid            TEXT    NOT NULL,
    source          TEXT    NOT NULL DEFAULT 'rss',       -- rss / podcast / youtube / wechat ...
    title           TEXT    NOT NULL,
    author          TEXT,
    url             TEXT    NOT NULL,
    language        TEXT,
    published_at    TEXT,                 -- ISO8601
    fetched_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    content_html    TEXT,
    content_md      TEXT,
    excerpt         TEXT,
    word_count      INTEGER,
    reading_minutes INTEGER,
    fetch_status    INTEGER NOT NULL DEFAULT 0,   -- 0未抓 1抓取中 2成功 3失败 4直入
    fetch_engine    TEXT,                 -- defuddle / readability / rss-direct / rss-fallback
    fetch_error     TEXT,
    fetched_full_at TEXT,
    llm_score       INTEGER,
    llm_summary     TEXT,
    llm_translated_md TEXT,
    llm_model       TEXT,
    llm_processed_at TEXT,
    content_hash    BLOB,                 -- 原 bytea，去重用
    is_duplicate    INTEGER NOT NULL DEFAULT 0,
    duplicate_of    INTEGER,
    is_archived     INTEGER NOT NULL DEFAULT 0,
    meta            TEXT    NOT NULL DEFAULT '{}',  -- JSON（原 jsonb）
    created_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    UNIQUE (source, guid)
);

CREATE INDEX IF NOT EXISTS idx_content_ctype      ON content (ctype);
CREATE INDEX IF NOT EXISTS idx_content_feed       ON content (feed_id);
CREATE INDEX IF NOT EXISTS idx_content_fetch      ON content (fetch_status) WHERE fetch_status IN (0, 3);
CREATE INDEX IF NOT EXISTS idx_content_published  ON content (published_at DESC);
CREATE INDEX IF NOT EXISTS idx_content_score      ON content (llm_score DESC) WHERE llm_score IS NOT NULL;
-- content_hash 为 BLOB，去重查询走 is_duplicate + hash 组合
CREATE INDEX IF NOT EXISTS idx_content_hash       ON content (content_hash) WHERE content_hash IS NOT NULL AND is_duplicate = 0;

-- ============================================================
-- 任务队列：抓取/转录/打分等异步任务
-- ============================================================
CREATE TABLE IF NOT EXISTS content_job (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    content_id   INTEGER NOT NULL REFERENCES content(id) ON DELETE CASCADE,
    jtype        TEXT    NOT NULL,          -- fetch / transcribe / score / translate
    status       INTEGER NOT NULL DEFAULT 0, -- 0待处理 1进行中 2完成 3失败 4取消
    priority     INTEGER NOT NULL DEFAULT 10,
    attempts     INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 3,
    payload      TEXT    NOT NULL DEFAULT '{}',  -- JSON
    result       TEXT,                          -- JSON
    error        TEXT,
    run_after    TEXT    NOT NULL DEFAULT (datetime('now')),
    started_at   TEXT,
    finished_at  TEXT,
    created_at   TEXT    NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_job_content ON content_job (content_id);
CREATE INDEX IF NOT EXISTS idx_job_claim   ON content_job (jtype, status, run_after);

-- ============================================================
-- 订阅源：RSS/播客/YouTube/微信等，独立后 feed_id 仅历史溯源
-- ============================================================
CREATE TABLE IF NOT EXISTS content_source (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    stype           TEXT    NOT NULL,        -- rss/podcast/youtube/wechat/x/xhs/mcp/api
    name            TEXT    NOT NULL,
    identifier      TEXT    NOT NULL,        -- feed url / channel id / 公众号 id
    config          TEXT    NOT NULL DEFAULT '{}',  -- JSON
    feed_id         INTEGER,                 -- 原 FreshRSS feed.id，历史溯源
    enabled         INTEGER NOT NULL DEFAULT 1,
    last_fetched_at TEXT,
    error           TEXT,
    created_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    UNIQUE (stype, identifier)
);

-- ============================================================
-- 分类策略：按分类控制自动抓取/翻译/打分（category_id 独立后改指 readboard 自己的分类）
-- ============================================================
CREATE TABLE IF NOT EXISTS category_policy (
    category_id    INTEGER PRIMARY KEY,
    auto_fetch     INTEGER NOT NULL DEFAULT 1,
    auto_translate INTEGER NOT NULL DEFAULT 0,
    auto_score     INTEGER NOT NULL DEFAULT 0,
    min_score_keep INTEGER NOT NULL DEFAULT 0
);
