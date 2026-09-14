#!/usr/bin/env python3
"""Validate Jekyll front matter / data files without external dependencies.

Catches the most common GitHub Pages build failures:
  * front matter opened with '---' but never closed
  * TAB characters inside YAML (kramdown/psych rejects them)
  * unquoted scalar values containing ': ' (e.g. title: A: B)
  * unbalanced quotes in front matter values
  * duplicate permalink / output URL conflicts
  * files that are not valid UTF-8

Usage: python scripts/check_frontmatter.py
"""
import os
import re
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXCLUDE_DIRS = {
    ".git", ".bundle", ".vscode", "dist", "tmp", "transfer",
    "vendor", "node_modules", "_site", "scripts",
}
PAGE_EXTS = {".md", ".markdown", ".html"}
DATA_EXTS = {".yml", ".yaml"}

KEY_RE = re.compile(r"^(\s*)(-\s+)?([A-Za-z_][\w\-]*):(.*)$")

errors = []
warnings = []
permalinks = defaultdict(list)


def read(rel, full):
    with open(full, "rb") as f:
        raw = f.read()
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        errors.append(f"[encoding] {rel}: not valid UTF-8 ({exc})")
        return None


def split_frontmatter(rel, text):
    """Return (list_of_lines, ok). ok=False if no front matter."""
    if not text.startswith("---"):
        return None, False
    lines = text.split("\n")
    for i in range(1, len(lines)):
        stripped = lines[i].rstrip()
        if stripped in ("---", "..."):
            return lines[1:i], True
    errors.append(f"[frontmatter] {rel}: opening '---' never closed")
    return None, False


def scan_yaml_lines(rel, lines, offset):
    """Structural YAML sanity checks on a list of lines."""
    in_block_scalar = False
    block_indent = None

    for idx, line in enumerate(lines):
        lineno = idx + offset

        if "\t" in line and not in_block_scalar:
            errors.append(f"[yaml] {rel}:{lineno}: TAB character in YAML is illegal")

        stripped = line.strip()

        # inside a block scalar (| or >) everything is literal text
        if in_block_scalar:
            if stripped == "":
                continue
            indent = len(line) - len(line.lstrip())
            if block_indent is None:
                block_indent = indent
            if indent >= block_indent:
                continue
            in_block_scalar = False
            block_indent = None

        if stripped == "" or stripped.startswith("#"):
            continue

        m = KEY_RE.match(line)
        if not m:
            continue

        value = m.group(4).strip()

        if value in ("|", ">", "|-", ">-", "|+", ">+"):
            in_block_scalar = True
            block_indent = None
            continue

        if not value or value.startswith("#"):
            continue

        # quoted values are safe; just check the closing quote exists
        if value[0] in "\"'":
            quote = value[0]
            closed = False
            i = 1
            while i < len(value):
                ch = value[i]
                if quote == '"' and ch == "\\":
                    i += 2
                    continue
                if ch == quote:
                    if quote == "'" and i + 1 < len(value) and value[i + 1] == "'":
                        i += 2
                        continue
                    closed = True
                    break
                i += 1
            if not closed:
                errors.append(
                    f"[yaml] {rel}:{lineno}: unbalanced {quote} quote -> {stripped}"
                )
            continue

        if value[0] in "[{":
            continue

        # strip trailing comment for plain scalars ( ' #' starts a comment)
        cpos = value.find(" #")
        if cpos != -1:
            value = value[:cpos].rstrip()
        if not value:
            continue

        # unquoted plain scalar: ': ' makes psych treat it as a nested mapping
        if ": " in value or value.endswith(":"):
            errors.append(
                f"[yaml] {rel}:{lineno}: unquoted value contains ':' "
                f"-> {stripped}  (wrap the value in quotes)"
            )
        elif value.startswith(("*", "&", "%", "@", "`")):
            warnings.append(
                f"[yaml] {rel}:{lineno}: value starts with reserved char "
                f"'{value[0]}' -> {stripped}"
            )


def parse_simple_map(lines):
    """Very small top-level key extractor (for permalink lookup)."""
    out = {}
    for line in lines:
        m = re.match(r"^([A-Za-z_][\w\-]*):\s*(.*)$", line)
        if m:
            out[m.group(1)] = m.group(2).strip().strip("\"'")
    return out


for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in EXCLUDE_DIRS]
    for name in filenames:
        ext = os.path.splitext(name)[1].lower()
        if ext not in PAGE_EXTS and ext not in DATA_EXTS:
            continue
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, ROOT).replace("\\", "/")
        text = read(rel, full)
        if text is None:
            continue

        if ext in DATA_EXTS:
            scan_yaml_lines(rel, text.split("\n"), 1)
            continue

        fm, ok = split_frontmatter(rel, text)
        if not ok:
            continue
        scan_yaml_lines(rel, fm, 2)
        meta = parse_simple_map(fm)
        if meta.get("permalink"):
            permalinks[meta["permalink"]].append(rel)

for link, files in sorted(permalinks.items()):
    if len(files) > 1:
        errors.append(f"[conflict] permalink '{link}' declared by: {', '.join(files)}")

if warnings:
    print(f"{len(warnings)} warning(s):")
    for w in warnings:
        print("  ?", w)
    print()

if errors:
    print(f"{len(errors)} error(s) found:\n")
    for e in errors:
        print("  x", e)
    sys.exit(1)

print("OK: front matter, data files and permalinks all structurally valid.")