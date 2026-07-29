-- 026: 内容处理引擎直接查询派生队列所需的局部索引。
-- 条目级 auto 标记 + 结果是否缺失是持久化任务状态；id DESC 支持最新优先。

CREATE INDEX IF NOT EXISTS idx_content_worker_score
ON content (auto_score, id DESC)
WHERE deleted_at IS NULL AND is_duplicate = 0 AND llm_score IS NULL;

CREATE INDEX IF NOT EXISTS idx_content_worker_translate
ON content (auto_translate, id DESC)
WHERE deleted_at IS NULL AND is_duplicate = 0
  AND LENGTH(TRIM(COALESCE(llm_translated_md, ''))) = 0;

CREATE INDEX IF NOT EXISTS idx_content_worker_summarize
ON content (auto_summarize, id DESC)
WHERE deleted_at IS NULL AND is_duplicate = 0
  AND LENGTH(TRIM(COALESCE(llm_summary, ''))) = 0;

CREATE INDEX IF NOT EXISTS idx_content_worker_transcribe
ON content (auto_transcribe, id DESC)
WHERE deleted_at IS NULL AND is_duplicate = 0
  AND LENGTH(TRIM(COALESCE(llm_transcript_md, ''))) = 0;
