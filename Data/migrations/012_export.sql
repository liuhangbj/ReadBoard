-- 012_export.sql — 后处理板块：导出规则 + 导出记录
-- 规则按筛选条件匹配已处理内容，渲染为 Markdown 交付到目标（Obsidian 仓库 / 通用 MD 目录 / Webhook）

CREATE TABLE IF NOT EXISTS export_rule (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    -- 筛选条件（JSON）：{"min_score":70,"source_ids":[...],"require_translated":false,
    --                    "require_transcribed":false,"require_summary":false,"starred_only":false}
    criteria TEXT NOT NULL DEFAULT '{}',
    -- 触发时机：score / translate / transcribe / manual（管线完成后自动触发 or 仅手动执行）
    trigger_on TEXT NOT NULL DEFAULT 'manual',
    -- 目标：obsidian（直写仓库）/ mddir（通用 Markdown 目录）/ webhook（POST JSON）
    target TEXT NOT NULL,
    -- 目标配置（JSON）：obsidian/mddir {"dir":"/path","subdir_by_source":true}
    --                   webhook {"url":"https://...","headers":{...}}
    target_config TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    last_run_at TEXT
);

CREATE TABLE IF NOT EXISTS export_record (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_id INTEGER NOT NULL REFERENCES export_rule(id) ON DELETE CASCADE,
    content_id INTEGER NOT NULL,
    -- delivered / failed / skipped
    status TEXT NOT NULL,
    -- 交付产物位置（文件路径或 webhook 返回码）
    destination TEXT,
    error TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    -- 同一规则对同一内容只交付一次（幂等——重跑不产生重复文件）
    UNIQUE (rule_id, content_id)
);

CREATE INDEX IF NOT EXISTS idx_export_record_rule ON export_record(rule_id, status);
