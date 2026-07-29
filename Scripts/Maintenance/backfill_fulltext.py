#!/usr/bin/env python3
"""回填 feed 全文到 content_md。

背景：一批文章 feed 里有全文（content_html ≥800），但早期被抓成 summary
（content_md 只是摘要 <500）。之后源改成 feed_full，但存量文章没回填。
本脚本把这些文章的 content_html 用 engine 的 html 模式（defuddle）转成
markdown 存进 content_md。纯本地、无网络、无 Jina。

安全：只 UPDATE 满足条件的行；转换失败/太短的跳过不动原数据；逐行提交可中断续跑。
"""
import argparse
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess

DEFAULT_DB = os.path.expanduser("~/Library/Application Support/ReadBoard/readboard.db")
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ENGINE = REPO_ROOT / "App/ReadBoard/Sources/ReadBoard/Resources/engine/fetch_engine.js"

DB = DEFAULT_DB
ENGINE = str(DEFAULT_ENGINE)
NODE = shutil.which("node") or "node"

MIN_HTML = 800   # content_html 至少这么长才算 feed 有全文
MIN_MD_KEEP = 500  # content_md 短于这个认为是摘要，需要回填
MIN_MD_OK = 40   # 转换结果至少这么长才算成功


def to_markdown(html: str) -> str | None:
    """包壳后喂 engine html 模式，返回 markdown 或 None。"""
    lower = html.lower()
    if "<html" in lower or "<!doctype" in lower:
        wrapped = html
    else:
        wrapped = ('<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>'
                   + html + "</body></html>")
    try:
        r = subprocess.run(
            [NODE, ENGINE, "html"],
            input=wrapped.encode("utf-8"),
            capture_output=True,
            timeout=60,
        )
    except subprocess.TimeoutExpired:
        return None
    if r.returncode != 0 or not r.stdout:
        return None
    md = r.stdout.decode("utf-8", errors="replace")
    return md if len(md) >= MIN_MD_OK else None


def main():
    global DB, ENGINE, NODE
    parser = argparse.ArgumentParser()
    parser.add_argument("limit", nargs="?", type=int, default=0, help="最多处理数量，0 表示全部")
    parser.add_argument("--db", default=os.environ.get("READBOARD_DB", DEFAULT_DB))
    parser.add_argument("--engine", default=os.environ.get("READBOARD_ENGINE", str(DEFAULT_ENGINE)))
    parser.add_argument("--node", default=os.environ.get("READBOARD_NODE_BIN", NODE))
    args = parser.parse_args()
    DB, ENGINE, NODE = args.db, args.engine, args.node
    limit = args.limit
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    sql = """
        SELECT c.id, c.content_html FROM content c
        JOIN content_source cs ON c.source_id = cs.id
        WHERE cs.stype NOT IN ('podcast','video') AND c.deleted_at IS NULL
          AND LENGTH(COALESCE(c.content_html,'')) >= ?
          AND (c.content_md IS NULL OR LENGTH(c.content_md) < ?)
        ORDER BY c.id
    """
    rows = cur.execute(sql, (MIN_HTML, MIN_MD_KEEP)).fetchall()
    total = len(rows)
    print(f"待回填 {total} 篇" + (f"（本次限量 {limit}）" if limit else ""))
    if limit:
        rows = rows[:limit]

    ok = fail = 0
    for i, row in enumerate(rows, 1):
        cid = row["id"]
        md = to_markdown(row["content_html"])
        if md:
            conn.execute(
                "UPDATE content SET content_md=?, fetch_status=2, fetch_engine='feed_full' WHERE id=?",
                (md, cid),
            )
            conn.commit()
            ok += 1
        else:
            fail += 1
        if i % 50 == 0 or i == len(rows):
            print(f"  进度 {i}/{len(rows)}  成功 {ok}  失败 {fail}", flush=True)

    print(f"完成：成功 {ok}，失败 {fail}，共处理 {len(rows)}")
    conn.close()


if __name__ == "__main__":
    main()
