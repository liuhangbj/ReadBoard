-- 015: 播客 feed 简介的中文翻译字段
-- 播客三标签阅读区：原文(content_html 简介)/译文(llm_excerpt_translated 简介翻译)/转录(llm_translated_md 中英对照)
-- 摘要译文独立存此列，与转录对照（llm_translated_md）分开，不再混用一个字段
ALTER TABLE content ADD COLUMN llm_excerpt_translated TEXT;
