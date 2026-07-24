#!/usr/bin/env python3
"""清理存量 content_md 里的抓取调试日志污染。

污染模式（113 条 huxiu 抓取记录）：
  Cleaned URL: <url> -> <url>
  Huxiu article detected, pre-processing HTML...
  ---
  <嵌套的 frontmatter（抓取脚本输出，真 metadata）>
  ---
  <正文>

清理策略：剥掉开头 2 行调试日志；嵌套 frontmatter 的 description 提取存回
excerpt（若为空），其余 frontmatter 行剥掉，正文保留。
"""
import sqlite3
import re
import sys

DB = "/Users/hangbits/readboard/Data/readboard.db"

def clean(md: str) -> tuple[str, str | None]:
    """返回 (清理后的正文, 提取的 description)。不匹配污染模式返回原文。"""
    if not md.startswith("Cleaned URL:"):
        return md, None
    lines = md.split("\n")
    # 跳过开头调试行，找到 frontmatter 起点 ---
    i = 0
    while i < len(lines) and not lines[i].strip() == "---":
        i += 1
    if i >= len(lines):
        return md, None  # 没找到 frontmatter，保守不动
    # frontmatter 块
    j = i + 1
    desc = None
    while j < len(lines) and lines[j].strip() != "---":
        m = re.match(r"^description:\s*(.+)$", lines[j])
        if m:
            desc = m.group(1).strip()
        j += 1
    body = "\n".join(lines[j + 1:]).strip()
    return body, desc

def main(dry_run: bool):
    conn = sqlite3.connect(DB)
    conn.execute("PRAGMA journal_mode=WAL;")
    rows = conn.execute(
        "SELECT id, content_md, excerpt FROM content WHERE content_md LIKE 'Cleaned URL%'"
    ).fetchall()
    print(f"匹配污染记录: {len(rows)} 条")
    cleaned = 0
    for cid, md, excerpt in rows:
        body, desc = clean(md)
        if body == md:
            continue
        if dry_run:
            if cleaned < 3:
                print(f"\n--- id={cid} 清理后前 120 字 ---\n{body[:120]}")
            cleaned += 1
        else:
            new_excerpt = excerpt if excerpt and excerpt.strip() else desc
            conn.execute(
                "UPDATE content SET content_md=?, excerpt=? WHERE id=?",
                (body, new_excerpt, cid))
            cleaned += 1
    if not dry_run:
        conn.commit()
        print(f"已清理 {cleaned} 条并提交")
    else:
        print(f"\n[dry-run] 将清理 {cleaned} 条（未写入）")
    conn.close()

if __name__ == "__main__":
    main(dry_run="--apply" not in sys.argv)
