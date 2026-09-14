#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""检查 _posts 目录下常见的 GitHub Pages 构建风险。

检查项：
  1. 文件名是否符合 YYYY-M-D-title 格式（Jekyll 强制要求，否则整站构建失败）
  2. 日期是否真实存在（如 2 月 30 日会导致 "Invalid date" 错误）
  3. 由 permalink 模板 /_posts/:year-:month-:day-:title/ 生成的输出 URL 是否冲突
  4. front matter 是否闭合、是否含非法 TAB
  5. 是否为合法 UTF-8

用法: python scripts/check_posts.py
"""
import datetime
import os
import re
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POSTS = os.path.join(ROOT, "_posts")

NAME_RE = re.compile(r"^(\d{4})-(\d{1,2})-(\d{1,2})-(.+)\.(md|markdown|html)$")

errors = []
urls = defaultdict(list)

names = sorted(
    n for n in os.listdir(POSTS)
    if os.path.isfile(os.path.join(POSTS, n))
)

for name in names:
    if not name.lower().endswith((".md", ".markdown", ".html")):
        errors.append(f"[name] _posts/{name}: 非文章文件放在 _posts 下（应移到子目录或 assets）")
        continue

    m = NAME_RE.match(name)
    if not m:
        errors.append(
            f"[name] _posts/{name}: 文件名不符合 'YYYY-M-D-标题.md'，Jekyll 会直接报错"
        )
        continue

    y, mo, da, title, _ext = m.groups()
    try:
        datetime.date(int(y), int(mo), int(da))
    except ValueError as exc:
        errors.append(f"[date] _posts/{name}: 日期非法 ({exc})")
        continue

    # permalink: /_posts/:year-:month-:day-:title/
    # Jekyll 的 :month/:day 会补零；:title 使用 slug
    slug = title.strip().lower()
    slug = slug.replace(" ", "-")
    url = f"/_posts/{y}-{int(mo):02d}-{int(da):02d}-{slug}/"
    urls[url].append(name)

    full = os.path.join(POSTS, name)
    with open(full, "rb") as f:
        raw = f.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        errors.append(f"[encoding] _posts/{name}: 不是合法 UTF-8 ({exc})")
        continue

    if not text.startswith("---"):
        errors.append(f"[frontmatter] _posts/{name}: 缺少 front matter（'---' 开头）")
        continue

    lines = text.split("\n")
    end = None
    for i in range(1, len(lines)):
        if lines[i].rstrip() in ("---", "..."):
            end = i
            break
    if end is None:
        errors.append(f"[frontmatter] _posts/{name}: front matter 未闭合")
        continue

    for i in range(1, end):
        if "\t" in lines[i]:
            errors.append(f"[yaml] _posts/{name}:{i + 1}: front matter 含 TAB 字符")

for url, files in sorted(urls.items()):
    if len(files) > 1:
        errors.append(f"[conflict] 输出 URL 冲突 {url} <- {', '.join(files)}")

print(f"扫描 {len(names)} 个文件，{len(urls)} 个输出 URL")
if errors:
    print(f"\n发现 {len(errors)} 个问题：\n")
    for e in errors:
        print("  x", e)
    sys.exit(1)

print("OK: _posts 文件名、日期、URL、front matter 均无问题。")