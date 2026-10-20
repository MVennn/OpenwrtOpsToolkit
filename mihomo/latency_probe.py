#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""探测 mihomo 策略组状态与各节点握手延迟。

只读：只调 `/proxies` 与 `/proxies/{name}/delay`（以及 `/group/{name}/delay`），
**不切组、不改配置**。

用法:
    python latency_probe.py
    python latency_probe.py --help

连接参数走环境变量：`MIHOMO_API`（默认 http://127.0.0.1:9999）、`MIHOMO_SECRET`（控制台开了 secret 时必填）。

**策略组名 / 节点名 / 探测 URL 都不写死在脚本里** —— 全部走环境变量，
默认是通用占位符（照抄订阅里的名字会一个都对不上）：

| 环境变量 | 含义 | 默认 |
|---|---|---|
| `MIHOMO_PROBE_GROUPS` | 要看的策略组（逗号分隔） | `GROUP_A,GROUP_B,GROUP_C` |
| `MIHOMO_PROBE_NODES` | 要测的节点（逗号分隔） | `NODE_A,NODE_B` |
| `MIHOMO_PROBE_URLS` | 探测目标 `名字=URL`（逗号分隔） | 三个公开 AI 站点 |
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

API = os.environ.get("MIHOMO_API", "http://127.0.0.1:9999").rstrip("/")

USAGE = """用法: python latency_probe.py [--help]

环境变量:
  MIHOMO_API         控制 API 基址，默认 http://127.0.0.1:9999
  MIHOMO_SECRET      控制台 secret（控制台开了 secret 时必填）
  MIHOMO_PROBE_GROUPS  策略组清单（逗号分隔），默认 GROUP_A,GROUP_B,GROUP_C
  MIHOMO_PROBE_NODES   节点清单（逗号分隔），默认 NODE_A,NODE_B
  MIHOMO_PROBE_URLS    探测目标 名字=URL（逗号分隔）
"""


def _split_env(name, default):
    raw = os.environ.get(name, "").strip()
    if not raw:
        return list(default)
    return [x.strip() for x in raw.split(",") if x.strip()]


def _probe_urls():
    raw = os.environ.get("MIHOMO_PROBE_URLS", "").strip()
    if not raw:
        return {
            "chatgpt": "https://chatgpt.com/",
            "gemini": "https://gemini.google.com/",
            "claude": "https://claude.ai/",
        }
    out = {}
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        if "=" in item:
            k, v = item.split("=", 1)
            out[k.strip()] = v.strip()
        else:
            out[item] = "https://" + item.lstrip("/")
    return out


GROUPS = _split_env("MIHOMO_PROBE_GROUPS", ["GROUP_A", "GROUP_B", "GROUP_C"])
NODES = _split_env("MIHOMO_PROBE_NODES", ["NODE_A", "NODE_B"])
URLS = _probe_urls()


def get(path, timeout=8):
    # mihomo 控制 API 开了 secret 时必须带 Authorization 头，否则一律 401
    req = urllib.request.Request(API + path)
    secret = os.environ.get("MIHOMO_SECRET", "").strip()
    if secret:
        req.add_header("Authorization", f"Bearer {secret}")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def probe(path, timeout=8):
    try:
        return get(path, timeout)
    except urllib.error.HTTPError as e:
        return "HTTP%d" % e.code
    except Exception as e:  # noqa: BLE001
        return type(e).__name__


def delay(node, url, timeout=5000):
    q = urllib.parse.urlencode({"url": url, "timeout": timeout})
    path = "/proxies/%s/delay?%s" % (urllib.parse.quote(node, safe=""), q)
    r = probe(path, timeout=timeout / 1000 + 3)
    if isinstance(r, dict):
        return r.get("delay")
    return r


def group_delay(group, url, timeout=5000):
    q = urllib.parse.urlencode({"url": url, "timeout": timeout})
    path = "/group/%s/delay?%s" % (urllib.parse.quote(group, safe=""), q)
    r = probe(path, timeout=timeout / 1000 + 3)
    if not isinstance(r, dict):
        return r
    vals = [
        v.get("delay") if isinstance(v, dict) else v
        for v in r.values()
    ]
    ok = sorted(v for v in vals if isinstance(v, int))
    return "min=%s" % (ok[0] if ok else "ERR")


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    proxies = get("/proxies")["proxies"]

    print("== group state ==")
    for g in GROUPS:
        p = proxies.get(g)
        if not p:
            print("%-16s MISSING" % g)
            continue
        print("%-16s type=%-9s now=%s" % (g, p.get("type"), p.get("now", "")))

    print("\n== per-node handshake delay (ms) ==")
    cols = list(URLS.items())
    print("node".ljust(24) + "".join(k.ljust(16) for k, _ in cols))
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {
            ex.submit(delay, node, url): (node, key)
            for node in NODES
            for key, url in cols
        }
        results = {}
        for f in as_completed(futs):
            results[futs[f]] = f.result()
    for node in NODES:
        row = node.ljust(24)
        for key, _ in cols:
            row += str(results.get((node, key), "-")).ljust(16)
        print(row)

    print("\n== group min handshake delay (ms) ==")
    print("group".ljust(16) + "".join(k.ljust(16) for k, _ in cols))
    for g in GROUPS:
        row = g.ljust(16)
        with ThreadPoolExecutor(max_workers=4) as ex:
            futs = {ex.submit(group_delay, g, url): key for key, url in cols}
            res = {futs[f]: f.result() for f in as_completed(futs)}
        for key, _ in cols:
            row += str(res.get(key, "-")).ljust(16)
        print(row)
    return 0


if __name__ == "__main__":
    sys.exit(main())
