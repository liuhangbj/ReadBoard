-- 统一 BiliBili UI 品牌名称；只迁移系统生成的 UID 占位名，不覆盖用户自定义名称。
UPDATE content_source
SET name = 'BiliBili UP 主 ' || identifier
WHERE stype = 'bilibili'
  AND name = 'B站 UP 主 ' || identifier;

PRAGMA user_version = 30;
