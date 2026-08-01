-- 视频平台的全文路径必须由 content_source.stype 决定，不能继续复用 defuddle。
UPDATE content_source
SET config = CASE
    WHEN json_valid(config) THEN json_set(config, '$.fetch_mode', 'youtube_subtitle')
    ELSE '{"fetch_mode":"youtube_subtitle"}'
END
WHERE stype = 'youtube';

UPDATE content_source
SET config = CASE
    WHEN json_valid(config) THEN json_set(config, '$.fetch_mode', 'bilibili_subtitle')
    ELSE '{"fetch_mode":"bilibili_subtitle"}'
END
WHERE stype = 'bilibili';
