-- 016: 标题的中文翻译字段
-- 媒体项「翻译」连标题一起翻，中文标题独立存此列。
-- 中栏标题(displayTitle)和阅读器标题栏(chineseTitle)都从此取——与简介译文(llm_excerpt_translated)分开，
-- 不再靠「excerptTranslated 第一行」猜标题（旧数据第一行是简介正文，会误取）
ALTER TABLE content ADD COLUMN llm_title_translated TEXT;
