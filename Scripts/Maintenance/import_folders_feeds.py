#!/usr/bin/env python3
"""把 FreshRSS 的 category(文件夹) + feed(订阅源) 归属迁进 readboard。

- folder: 1.快讯 / 2.深度 / WeChat (跳过空的 Uncategorized)
- content_source: stype=rss(公众号也先当普通 RSS), identifier=feed url,
  folder_id 按 FreshRSS category 归属, feed_id 保留 FreshRSS feed.id 溯源
- 幂等: 按 name/identifier 去重, 可重跑
"""
import argparse
import os
import sqlite3

DEFAULT_DB = os.path.expanduser("~/Library/Application Support/ReadBoard/readboard.db")
DEFAULT_PG_DSN = "host=localhost port=5432 dbname=freshrss user=freshrss"
PG_DSN = DEFAULT_PG_DSN
RB_DB = DEFAULT_DB

# FreshRSS category id -> 是否导入(跳过 Uncategorized)
CATEGORIES = {10: "1.快讯", 11: "2.深度", 7: "WeChat"}

def main():
    import psycopg2
    pg = psycopg2.connect(PG_DSN)
    cur = pg.cursor()
    cur.execute("""
        SELECT f.id, f.name, f.url, f.category
        FROM liuhangbj_feed f
        WHERE f.category = ANY(%s)
        ORDER BY f.category, f.name;
    """, (list(CATEGORIES.keys()),))
    feeds = cur.fetchall()
    pg.close()

    rb = sqlite3.connect(RB_DB)
    rbc = rb.cursor()

    # 1. 建 folder, 记录 category_id -> folder_id 映射
    cat_to_folder = {}
    for cat_id, name in CATEGORIES.items():
        rbc.execute("INSERT OR IGNORE INTO folder (name) VALUES (?)", (name,))
        rbc.execute("SELECT id FROM folder WHERE name = ?", (name,))
        cat_to_folder[cat_id] = rbc.fetchone()[0]

    # 2. 迁 feed -> content_source
    added = skipped = 0
    for feed_id, name, url, cat_id in feeds:
        folder_id = cat_to_folder[cat_id]
        # 幂等: 同 stype+identifier 已存在则跳过(但补 folder_id)
        rbc.execute("SELECT id, folder_id FROM content_source WHERE stype='rss' AND identifier=?", (url,))
        row = rbc.fetchone()
        if row:
            if row[1] is None:
                rbc.execute("UPDATE content_source SET folder_id=? WHERE id=?", (folder_id, row[0]))
            skipped += 1
            continue
        rbc.execute("""
            INSERT INTO content_source (stype, name, identifier, feed_id, enabled, folder_id)
            VALUES ('rss', ?, ?, ?, 1, ?)
        """, (name, url, feed_id, folder_id))
        added += 1

    rb.commit()

    # 3. 汇总
    rbc.execute("SELECT f.name, COUNT(s.id) FROM folder f LEFT JOIN content_source s ON s.folder_id=f.id GROUP BY f.id ORDER BY f.name")
    summary = rbc.fetchall()
    rb.close()

    print(f"folder 映射: {cat_to_folder}")
    print(f"新增源 {added}, 已存在跳过 {skipped}, 总计 feed {len(feeds)}")
    print("各文件夹源数:")
    for name, cnt in summary:
        print(f"  {name}: {cnt}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=os.environ.get("READBOARD_DB", DEFAULT_DB))
    parser.add_argument("--pg-dsn", default=os.environ.get("READBOARD_PG_DSN", DEFAULT_PG_DSN))
    args = parser.parse_args()
    RB_DB, PG_DSN = args.db, args.pg_dsn
    main()
