#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 本仓分叉变体；上游参考：ClientTriage/tools/check-docs.py（2026-11-01 bug 奇偶同步）
"""文档自检：相对链接、锚点、孤文档、一句话引言块。

用法：
    python tools/check-docs.py            # 检查全仓（跳过 third-party/ 等 vendored 目录）
    python tools/check-docs.py docs/      # 只检查指定子目录

退出码：0 全部通过 / 1 有问题。
这是本仓 docs/DOC-RULES.md 里那几条规则的**可执行版本** —— 规则写在文档里，
但要在 CI 里真能拦住人，就得有个脚本。
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = {".git", "node_modules", "dist", "__pycache__", "third-party", "memories", "evidence",
            # vault/ 被 .gitignore 排除，不属于版本库里的文档
            "vault",
            # .work/ 是本地工作区（草稿、台账、工具产物），不入库，不是版本库里的文档
            ".work", ".codegraph"}
# 冻结目录：归档 / 拆分记录是**历史**，不套用活文档的规则（引言块、孤儿判定）
FROZEN_DIRS = ("docs/archive/", "docs/split/", "archive/")
SKIP_EXT = {".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".mrs", ".gz", ".pyc", ".woff", ".woff2"}
LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
HAS_ONE_LINER = re.compile(r"一句话")
# DOC-RULES：引言块必须在**开头**。只查文件头部若干行 —— 若扫全文，一句话沉到
# 文档末尾也算通过，检查就形同虚设（漏报）。现有文档全部在头部 10 行内。
ONE_LINER_HEAD = 10
EXAMPLE = re.compile(r"^文档名\.md#")


def slugify(title: str) -> str:
    s = title.strip().lower()
    s = re.sub(r"[^\w\s一-鿿-]", "", s)
    return re.sub(r"\s+", "-", s)


def collect(dirs):
    mds = []
    for d in dirs:
        base = os.path.normpath(os.path.join(ROOT, d)) if not os.path.isabs(d) else os.path.normpath(d)
        if os.path.isfile(base):
            mds.append(os.path.normpath(base))
            continue
        for dp, dn, fn in os.walk(base):
            dn[:] = [x for x in dn if x not in SKIP_DIRS]
            for f in fn:
                if not f.endswith(".md"):
                    continue
                norm = os.path.normpath(os.path.join(dp, f))
                rel = rel_to_root(norm)
                if any(rel.startswith(fd) or fd in rel for fd in FROZEN_DIRS):
                    continue
                mds.append(norm)
    return sorted(set(mds))


def rel_to_root(p: str) -> str:
    # 跨盘符（Windows，如仓在 F: 被检目录在 C:）时 relpath 抛 ValueError，
    # 整个脚本会带 traceback 崩掉 —— 用绝对路径顶上，至少能干净报错。
    try:
        return os.path.relpath(p, ROOT).replace(os.sep, "/")
    except ValueError:
        return p.replace(os.sep, "/")


def anchors_of(path: str) -> set[str]:
    # utf-8-sig：文件带 BOM 时把首行 BOM 剥掉，否则 `^#{1,6}` 匹配不到第一个标题，
    # 指向首节锚点的链接会误报「锚点不存在」。
    try:
        s = open(path, encoding="utf-8-sig", errors="replace").read()
    except OSError:
        return set()
    a = set(re.findall(r'<a\s+id="([^"]+)"', s))
    a |= {slugify(t) for t in re.findall(r"^#{1,6}\s+(.*)$", s, re.M)}
    return a


def main() -> int:
    targets = sys.argv[1:] or ["."]
    mds = collect(targets)
    if not mds:
        print("没有找到 .md 文件")
        return 1
    anchor_map = {m: anchors_of(m) for m in mds}
    problems: list[str] = []
    linked: set[str] = set()

    for m in mds:
        try:
            s = open(m, encoding="utf-8-sig", errors="replace").read()
        except OSError:
            continue
        rel = rel_to_root(m)
        for link in LINK.findall(s):
            if link.startswith(("http://", "https://", "mailto:")):
                continue
            if link.startswith("#"):
                if link[1:] and link[1:] not in anchor_map[m]:
                    problems.append(f"{rel}: 锚点不存在 → {link}")
                continue
            if EXAMPLE.match(link):
                continue  # 文档规则里的格式示例（形如 文档名.md#锚点）
            path, _, frag = link.partition("#")
            target = os.path.normpath(os.path.join(os.path.dirname(m), path))
            if not os.path.exists(target):
                problems.append(f"{rel}: 链接目标不存在 → {link}")
                continue
            linked.add(os.path.abspath(target))
            # 链接指向**目录**时，目录下的文档也算被引用（索引里常见 `archive/` 这种写法）
            if os.path.isdir(target):
                for dp2, dn2, fn2 in os.walk(target):
                    for f2 in fn2:
                        if f2.endswith(".md"):
                            linked.add(os.path.abspath(os.path.join(dp2, f2)))
            if frag and target.endswith(".md"):
                # 冻结目录（docs/archive/ 等）里的文档没进 anchor_map —— 按需补算锚点，
                # 否则链进归档文档的任何 #锚点 都会被误报「目标锚点不存在」。
                if target not in anchor_map:
                    anchor_map[target] = anchors_of(target)
                if frag not in anchor_map[target]:
                    problems.append(f"{rel}: 目标锚点不存在 → {link}")
        # 根 README 是面向用户的门面（对齐系列仓 gsauxiliary 的格式），不套文档引言块规则
        head_lines = s.splitlines()[:ONE_LINER_HEAD]
        if (not any(HAS_ONE_LINER.search(line) for line in head_lines)
                and rel != "README.md"
                and rel != "docs/DOC-RULES.md"
                and not rel.startswith("docs/release-notes/")):
            problems.append(f"{rel}: 开头缺少「一句话」引言块")

    for m in mds:
        rel = rel_to_root(m)
        if rel.startswith("docs/") and os.path.abspath(m) not in linked and rel != "docs/README.md":
            problems.append(f"{rel}: 孤儿文档 —— 没有被任何文档引用（也未进 docs/README.md 索引）")

    if problems:
        print(f"✗ {len(problems)} 个问题：")
        for p in problems:
            print("   ", p)
        return 1
    print(f"✓ {len(mds)} 篇文档全部通过（链接 / 锚点 / 引言块 / 孤儿）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
