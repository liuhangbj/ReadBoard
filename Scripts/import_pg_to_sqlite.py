#!/usr/bin/env python3
"""readboard: PostgreSQL CSV → SQLite 导入脚本
处理类型转换：hex→BLOB、timestamptz→ISO、空串→NULL、jsonb 保留文本
"""
import csv
import sqlite3
import sys
import os

EXPORT_DIR = open('/tmp/readboard_export_dir.txt').read().strip()
DB = '/Users/hangbits/readboard/Data/readboard.db'

csv.field_size_limit(sys.maxsize)

def norm_ts(v):
    """timestamptz 'YYYY-MM-DD HH:MM:SS.ffffff+TZ' → ISO，空→None"""
    if v is None or v == '':
        return None
    return v.strip()

def norm(v):
    """空串 → None"""
    return None if v == '' else v

def norm_int(v):
    if v is None or v == '':
        return None
    return int(v)

def hex_to_blob(v):
    if v is None or v == '':
        return None
    return bytes.fromhex(v)

conn = sqlite3.connect(DB)
cur = conn.cursor()

def import_content():
    path = f'{EXPORT_DIR}/content.csv'
    n = 0
    with open(path, newline='', encoding='utf-8') as f:
        r = csv.DictReader(f)
        batch = []
        for row in r:
            batch.append((
                norm_int(row['id']), norm_int(row['entry_id']), norm_int(row['feed_id']),
                row['ctype'], row['guid'], row['source'], row['title'], norm(row['author']),
                row['url'], norm(row['language']), norm_ts(row['published_at']), norm_ts(row['fetched_at']),
                norm(row['content_html']), norm(row['content_md']), norm(row['excerpt']),
                norm_int(row['word_count']), norm_int(row['reading_minutes']),
                norm_int(row['fetch_status']), norm(row['fetch_engine']), norm(row['fetch_error']),
                norm_ts(row['fetched_full_at']), norm_int(row['llm_score']), norm(row['llm_summary']),
                norm(row['llm_translated_md']), norm(row['llm_model']), norm_ts(row['llm_processed_at']),
                hex_to_blob(row['content_hash']), norm_int(row['is_duplicate']), norm_int(row['duplicate_of']),
                norm_int(row['is_archived']), row['meta'] or '{}', norm_ts(row['created_at']), norm_ts(row['updated_at']),
            ))
            if len(batch) >= 500:
                cur.executemany('''INSERT OR REPLACE INTO content
                    (id,entry_id,feed_id,ctype,guid,source,title,author,url,language,published_at,fetched_at,
                     content_html,content_md,excerpt,word_count,reading_minutes,fetch_status,fetch_engine,
                     fetch_error,fetched_full_at,llm_score,llm_summary,llm_translated_md,llm_model,llm_processed_at,
                     content_hash,is_duplicate,duplicate_of,is_archived,meta,created_at,updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''', batch)
                n += len(batch)
                batch = []
                if n % 10000 == 0:
                    print(f'  content ... {n}', flush=True)
        if batch:
            cur.executemany('''INSERT OR REPLACE INTO content
                (id,entry_id,feed_id,ctype,guid,source,title,author,url,language,published_at,fetched_at,
                 content_html,content_md,excerpt,word_count,reading_minutes,fetch_status,fetch_engine,
                 fetch_error,fetched_full_at,llm_score,llm_summary,llm_translated_md,llm_model,llm_processed_at,
                 content_hash,is_duplicate,duplicate_of,is_archived,meta,created_at,updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''', batch)
            n += len(batch)
    conn.commit()
    return n

def import_job():
    n = 0
    with open(f'{EXPORT_DIR}/job.csv', newline='', encoding='utf-8') as f:
        for row in csv.DictReader(f):
            cur.execute('''INSERT OR REPLACE INTO content_job
                (id,content_id,jtype,status,priority,attempts,max_attempts,payload,result,error,run_after,started_at,finished_at,created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
                (norm_int(row['id']), norm_int(row['content_id']), row['jtype'], norm_int(row['status']),
                 norm_int(row['priority']), norm_int(row['attempts']), norm_int(row['max_attempts']),
                 row['payload'] or '{}', norm(row['result']), norm(row['error']),
                 norm_ts(row['run_after']), norm_ts(row['started_at']), norm_ts(row['finished_at']), norm_ts(row['created_at'])))
            n += 1
    conn.commit()
    return n

def import_source():
    n = 0
    with open(f'{EXPORT_DIR}/source.csv', newline='', encoding='utf-8') as f:
        for row in csv.DictReader(f):
            cur.execute('''INSERT OR REPLACE INTO content_source
                (id,stype,name,identifier,config,feed_id,enabled,last_fetched_at,error,created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?)''',
                (norm_int(row['id']), row['stype'], row['name'], row['identifier'], row['config'] or '{}',
                 norm_int(row['feed_id']), norm_int(row['enabled']), norm_ts(row['last_fetched_at']),
                 norm(row['error']), norm_ts(row['created_at'])))
            n += 1
    conn.commit()
    return n

def import_policy():
    n = 0
    with open(f'{EXPORT_DIR}/policy.csv', newline='', encoding='utf-8') as f:
        for row in csv.DictReader(f):
            cur.execute('''INSERT OR REPLACE INTO category_policy
                (category_id,auto_fetch,auto_translate,auto_score,min_score_keep) VALUES (?,?,?,?,?)''',
                (norm_int(row['category_id']), norm_int(row['auto_fetch']), norm_int(row['auto_translate']),
                 norm_int(row['auto_score']), norm_int(row['min_score_keep'])))
            n += 1
    conn.commit()
    return n

print('导入 content ...', flush=True)
c = import_content()
print(f'  → {c} 行', flush=True)
print('导入 content_job ...', flush=True)
j = import_job()
print(f'  → {j} 行', flush=True)
print('导入 content_source ...', flush=True)
s = import_source()
print(f'  → {s} 行', flush=True)
print('导入 category_policy ...', flush=True)
p = import_policy()
print(f'  → {p} 行', flush=True)

# 重置自增序列，避免后续插入撞 id
cur.execute("DELETE FROM sqlite_sequence")
for t, seq in [('content', c), ('content_job', j), ('content_source', s)]:
    cur.execute("INSERT INTO sqlite_sequence(name, seq) VALUES (?, (SELECT COALESCE(MAX(id),0) FROM " + t + "))", (t,))
conn.commit()
conn.close()
print('✓ 全部导入完成', flush=True)
