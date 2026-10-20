#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""【腾讯系 CDN 专项】在抓日志的同时发起实际请求，观察 mihomo 为这些域名命中了哪条规则。

用法:
    python qq_rule_probe.py [域名...]
    python qq_rule_probe.py --help

连接参数走环境变量：`MIHOMO_API`（默认 http://127.0.0.1:9999）、
`MIHOMO_HOST` / `MIHOMO_PORT`、`MIHOMO_SECRET`（必填）。

**策略组名不写死在脚本里** —— 用环境变量指定，默认是通用占位符：

| 环境变量 | 含义 | 默认 |
|---|---|---|
| `MIHOMO_GROUP_PROXY` | 代理组（对照组） | `GROUP_A` |
| `MIHOMO_GROUP_DIRECT` | 直连组（对照组） | `DIRECT_GROUP` |
"""
import json, os, socket, sys, threading, time, urllib.parse
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mihomo"))
from mihomo_api import api, open_socket, host_header, auth_header

GROUP_PROXY = os.environ.get("MIHOMO_GROUP_PROXY", "GROUP_A").strip()
GROUP_DIRECT = os.environ.get("MIHOMO_GROUP_DIRECT", "DIRECT_GROUP").strip()

lines = []
stop = threading.Event()

USAGE = """用法: python qq_rule_probe.py [域名...]

例: python qq_rule_probe.py gchat.qpic.cn

环境变量:
  MIHOMO_API / MIHOMO_HOST / MIHOMO_PORT / MIHOMO_SECRET
  MIHOMO_GROUP_PROXY    代理组，默认 GROUP_A
  MIHOMO_GROUP_DIRECT   直连组，默认 DIRECT_GROUP
"""


def stream_logs():
    s = open_socket(3)
    s.sendall((f"GET /logs?level=debug HTTP/1.1\r\nHost: {host_header()}\r\n"
               f"Authorization: {auth_header()}\r\nConnection: close\r\n\r\n").encode())
    buf = b""
    while not stop.is_set():
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            continue
        except Exception:
            break
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            raw, _, buf = buf.partition(b"\n")
            raw = raw.strip()
            if not raw:
                continue
            try:
                o = json.loads(raw.decode("utf-8", "replace"))
                lines.append((o.get("type", ""), o.get("payload", "")))
            except Exception:
                pass
    s.close()


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    domains = sys.argv[1:] or ["gchat.qpic.cn", "www.baidu.com"]
    api("/configs", method="PATCH", body=json.dumps({"log-level": "debug"}).encode(),
        timeout=60, tries=20)
    th = threading.Thread(target=stream_logs, daemon=True)
    th.start()
    time.sleep(1.5)

    for d in domains:
        url = "https://" + d + "/"
        for g in [GROUP_PROXY, GROUP_DIRECT]:
            try:
                r = api(f"/proxies/{urllib.parse.quote(g)}/delay?timeout=10000&url={urllib.parse.quote(url, safe='')}",
                        timeout=60, tries=15)
                print(f"  {g:12s} {url} -> {r}")
            except Exception as e:
                print(f"  {g:12s} {url} -> ERR {e}")
        time.sleep(1.0)

    time.sleep(2)
    stop.set()
    try:
        api("/configs", method="PATCH", body=json.dumps({"log-level": "info"}).encode(),
            timeout=60, tries=20)
    except Exception as e:
        print("恢复日志级别失败:", e)

    print("\n=== 与目标域名相关的日志 ===")
    hit = False
    for t, p in lines:
        for d in domains:
            if d in p:
                print(f"[{t}] {p}")
                hit = True
    if not hit:
        print("（无匹配行——delay 测试可能不走规则引擎，改用其它方式验证）")
        print("\n=== 全部 info 级连接行 ===")
        for t, p in lines:
            if t == "info" and "[TCP]" in p:
                print(f"[{t}] {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
