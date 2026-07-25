-- 统一 content_hash 为 TEXT hex（64 字符小写），修 P0-1 去重失效+数据丢失。
-- 背景：列定义 BLOB（PG bytea 迁来），存量 blob=32 字节原始 SHA256、text=64 字符 hex、
-- NULL=未算。代码 contentHash() 生成 hex String 查 BLOB 列——SQLite 弱类型 BLOB≠TEXT
-- 比对恒 false，跨源去重失效；唯一索引又把同 hash 第二次 INSERT 打回事务回滚丢数据。
-- 统一策略：全部转 64 字符小写 hex TEXT。
--   blob(32 字节) → lower(hex(content_hash)) 转 64 字符 hex
--   text(已是 hex) → lower() 统一小写
--   NULL → 不动（老数据没 hash，无法补算 url/title 归一化，保持 NULL 不参与去重）

-- SQLite 不能直接改列类型，用"新列 + 拷贝 + 换名"重建。但 content 表大（67k 行），
-- 且有多处依赖（索引/触发器）。更稳妥：直接 UPDATE 转值（BLOB/TEXT 在 SQLite 是同列
-- 弱类型，UPDATE 改写存储类型即可，不用重建表）。

-- 1) blob → hex text（lower(hex()) 把 32 字节转 64 字符小写 hex）
UPDATE content
SET content_hash = lower(hex(content_hash))
WHERE typeof(content_hash) = 'blob';

-- 2) text → 统一小写（防止有大写 hex 混入）
UPDATE content
SET content_hash = lower(content_hash)
WHERE typeof(content_hash) = 'text';

-- 3) 去掉 idx_content_hash_primary 唯一索引——它把"应用层判 dup + INSERT is_duplicate=1"
--    的正常流程也打回（第二次同 hash 走 is_duplicate=1 才该过，但类型不匹配时 SELECT
--    miss 会走 is_duplicate=0 被唯一索引炸掉整个事务丢数据）。去重交给应用层事务内
--    判重（SourceStore.upsertContent 的 SELECT 判 dup + INSERT is_duplicate=1），
--    不再靠 DB 唯一约束硬拦（硬拦会把判重失误放大成数据丢失）。
DROP INDEX IF EXISTS idx_content_hash_primary;

-- 保留普通索引 idx_content_hash（查重加速，非唯一不拦插入）。
