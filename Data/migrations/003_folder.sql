-- readboard schema v3: 文件夹实体 + 文件夹级管线开关
-- folder 存管线开关 config(auto_score/auto_translate/auto_summarize/auto_transcribe, 默认全关)
-- 生效逻辑: 某管线对某源生效 = 源开关 OR 文件夹开关(文件夹开 = 全组开, 源可单独加开)

CREATE TABLE IF NOT EXISTS folder (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL UNIQUE,
    config     TEXT    NOT NULL DEFAULT '{}',   -- JSON, 四管线开关
    created_at TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- content_source 归属文件夹(NULL = 未分组)
ALTER TABLE content_source ADD COLUMN folder_id INTEGER REFERENCES folder(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_source_folder ON content_source (folder_id);
