-- 018: 新增 llm_transcript_md 列，拆出独立的转录稿字段
-- 原 llm_excerpt_translated 改名为 llm_transcript_md（语义：转录稿）
-- 播客类互换 llm_translated_md ↔ llm_transcript_md：
--   播客的「简介翻译」进 llm_translated_md（统一译��标签读源）
--   播客的「旧转录/翻译稿」进 llm_transcript_md（转录标签独立展示）

ALTER TABLE content ADD COLUMN llm_transcript_md TEXT;

-- 全量：llm_excerpt_translated 数据迁入新列
UPDATE content SET llm_transcript_md = llm_excerpt_translated;

-- 播客互换 llm_translated_md ↔ llm_transcript_md（用 llm_excerpt_translated 作中转位）
UPDATE content SET llm_excerpt_translated = llm_translated_md WHERE ctype = 'podcast';
UPDATE content SET llm_translated_md    = llm_transcript_md WHERE ctype = 'podcast';
UPDATE content SET llm_transcript_md    = llm_excerpt_translated WHERE ctype = 'podcast';
