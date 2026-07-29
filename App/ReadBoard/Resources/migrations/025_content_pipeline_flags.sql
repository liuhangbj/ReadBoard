-- 025: content 表增加 per-item 管线开关（NULL = 未设，回退读源配置，过渡兼容存量）

ALTER TABLE content ADD COLUMN auto_score INTEGER DEFAULT NULL;
ALTER TABLE content ADD COLUMN auto_translate INTEGER DEFAULT NULL;
ALTER TABLE content ADD COLUMN auto_summarize INTEGER DEFAULT NULL;
ALTER TABLE content ADD COLUMN auto_transcribe INTEGER DEFAULT NULL;
