#!/usr/bin/env python3
"""校验 openwrt/ 下 shell 脚本里的 shared 块没有漂移。

守卫脚本是「单文件 scp 到路由器」的部署形态，没有 include 机制，公共实现只能
复制。为了不让复制版本各改各的（PITFALLS P35），凡带标记的块都用同一份正文：

    # >>> shared:<id> >>>
    ...正文...
    # <<< shared:<id> <<<

本工具把同一 id 的所有副本取出来，剥掉行首行尾空白与空行后逐字比对。
缩进差异（traffic-stats.sh 用 Tab）不算差异；其余任何差异都报错。

用法：
    python tools/check-shell-shared-blocks.py            # 默认扫 openwrt/
    python tools/check-shell-shared-blocks.py --dir openwrt
退出码：0 = 全部一致；1 = 有漂移/标记不配对；2 = 扫描目录不存在。
"""

import argparse
import os
import re
import sys

OPEN_RE = re.compile(r"^[ \t]*# >>> shared:([A-Za-z0-9._-]+) >>>[ \t]*$")
CLOSE_RE = re.compile(r"^[ \t]*# <<< shared:([A-Za-z0-9._-]+) <<<[ \t]*$")
SHEBANG = re.compile(r"^#!.*\b(ba)?sh\b")


def norm(lines):
    out = []
    for ln in lines:
        s = ln.strip()
        if s:
            out.append(s)
    return out


def scan_file(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        raw = fh.read().split("\n")
    if not raw or not SHEBANG.match(raw[0] or ""):
        return {}
    blocks = {}
    cur_id = None
    cur_start = 0
    buf = []
    for idx, line in enumerate(raw, 1):
        m = OPEN_RE.match(line)
        if m:
            if cur_id is not None:
                raise ValueError("%s:%d 上一个 shared 块 %s 没闭合" % (path, cur_start, cur_id))
            cur_id = m.group(1)
            cur_start = idx
            buf = []
            continue
        m = CLOSE_RE.match(line)
        if m:
            if cur_id is None:
                raise ValueError("%s:%d 出现孤立闭合标记 %s" % (path, idx, m.group(1)))
            if m.group(1) != cur_id:
                raise ValueError("%s:%d 闭合标记 %s 与开启标记 %s 不配对" % (path, idx, m.group(1), cur_id))
            blocks[cur_id] = (cur_start, idx, norm(buf))
            cur_id = None
            buf = []
            continue
        if cur_id is not None:
            buf.append(line)
    if cur_id is not None:
        raise ValueError("%s:%d shared 块 %s 没有闭合标记" % (path, cur_start, cur_id))
    return blocks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="openwrt")
    args = ap.parse_args()
    root = args.dir
    if not os.path.isdir(root):
        print("[shared] 目录不存在: %s" % root, file=sys.stderr)
        return 2

    seen = {}
    errors = []
    files = 0
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            try:
                blocks = scan_file(path)
            except ValueError as exc:
                errors.append(str(exc))
                continue
            if blocks:
                files += 1
            for bid, (start, end, body) in blocks.items():
                seen.setdefault(bid, []).append((path, start, end, body))

    for bid in sorted(seen):
        copies = seen[bid]
        base_path, base_start, base_end, base_body = copies[0]
        for path, start, end, body in copies[1:]:
            if body != base_body:
                errors.append(
                    "shared:%s 漂移 —— %s:%d-%d 与 %s:%d-%d 正文不同"
                    % (bid, base_path, base_start, base_end, path, start, end)
                )
        if len(copies) == 1:
            print("[shared] 提示: shared:%s 只有一份副本（%s:%d-%d）"
                  % (bid, base_path, base_start, base_end))

    for bid in sorted(seen):
        locs = ", ".join("%s:%d" % (p, s) for p, s, _e, _b in seen[bid])
        print("[shared] %-12s %d 份  %s" % (bid, len(seen[bid]), locs))

    if errors:
        for e in errors:
            print("[shared] FAIL " + e, file=sys.stderr)
        return 1
    print("[shared] OK %d 个块 / %d 个脚本，全部一致" % (len(seen), files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
