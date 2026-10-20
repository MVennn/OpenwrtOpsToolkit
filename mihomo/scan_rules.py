#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""流式扫描 mihomo `/rules` 全量展开规则，提取指定域名相关的条目。

用途：确认有没有规则把某些域名指向 REJECT 或某个代理组。
`/rules` 响应可能十几 MB，整份读进内存没必要 —— 这里边收边切。

用法:
    python scan_rules.py [持续秒数] [匹配正则]
    python scan_rules.py --help

连接参数走环境变量：`MIHOMO_API`（默认 http://127.0.0.1:9999）、
`MIHOMO_HOST` / `MIHOMO_PORT`、`MIHOMO_SECRET`（必填）。

匹配正则（可选，命令行参数优先于环境变量 `MIHOMO_RULE_PATTERN`）：
- 不给 → 匹配所有「像域名」的 payload；
- 给了 → 只匹配 payload 里含该正则的条目，例如 `qpic|gtimg`。
"""
import json, os, re, socket, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mihomo_api import open_socket, host_header, auth_header

# cn 规则集会被展开成上万个条目，只看指向非 cn 的
SKIP = {"cn"}

USAGE = """用法: python scan_rules.py [持续秒数] [匹配正则]

例:
  python scan_rules.py 900                 # 扫全部「像域名」的规则
  python scan_rules.py 900 'qpic|gtimg'    # 只看 payload 含这些词的规则

环境变量: MIHOMO_API / MIHOMO_HOST / MIHOMO_PORT / MIHOMO_SECRET / MIHOMO_RULE_PATTERN
"""


def build_pattern(pattern):
    if pattern:
        return re.compile(
            rb'"payload":"([^"]*(?:%s)[^"]*)"[^}]*?"proxy":"([^"]*)"' % pattern.encode("utf-8"))
    # 默认：payload 里带点或冒号 —— 即「像域名/像 IP」的条目
    return re.compile(rb'"payload":"([^"]*[.:][^"]*)"[^}]*?"proxy":"([^"]*)"')


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    limit = float(sys.argv[1]) if len(sys.argv) > 1 else 900
    pattern = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("MIHOMO_RULE_PATTERN", "").strip()
    pat = build_pattern(pattern)
    print(f"匹配模式: {pattern or '(所有像域名的 payload)'}")
    s = open_socket(10)
    s.sendall((f"GET /rules HTTP/1.1\r\nHost: {host_header()}\r\n"
               f"Authorization: {auth_header()}\r\nConnection: close\r\n\r\n").encode())
    stop = time.time() + limit
    buf = b""
    total = 0
    hits = []
    seen = set()
    t0 = time.time()
    while time.time() < stop:
        try:
            chunk = s.recv(1 << 20)
        except socket.timeout:
            continue
        except Exception as e:
            print(f"[err] {e}")
            break
        if not chunk:
            break
        total += len(chunk)
        buf += chunk
        # 逐条 JSON 规则切分
        while True:
            i = buf.find(b'{"type":')
            if i < 0:
                if len(buf) > 1 << 20:
                    buf = buf[-100:]
                break
            j = buf.find(b"},{", i)
            if j < 0:
                buf = buf[i:]
                break
            blob = buf[i:j + 1]
            buf = buf[j + 2:]
            m = pat.search(blob)
            if m:
                payload = m.group(1).decode("utf-8", "replace")
                proxy = m.group(2).decode("utf-8", "replace")
                key = (payload, proxy)
                if key not in seen:
                    seen.add(key)
                    hits.append(key)
        if total % (20 << 20) < (1 << 20):
            print(f"  已扫描 {total/1e6:.0f} MB, {time.time()-t0:.0f}s, 命中 {len(hits)}")
    s.close()
    print(f"\n扫描结束：{total/1e6:.1f} MB, {time.time()-t0:.0f}s")
    print(f"相关规则 {len(hits)} 条：")
    for p, g in sorted(hits):
        print(f"  {p:44s} -> {g}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
