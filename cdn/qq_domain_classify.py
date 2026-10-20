#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""【腾讯系 CDN 专项】逐个域名判定它是否落在路由器的 cn 规则集内。

- 落在 cn  → DNS 走国内 DoH（doh.pub / alidns），路由命中 RULE-SET,cn → 直连
- 不在 cn  → DNS 走境外 DoH（经代理出口），路由命中兜底组 → 代理出口

用法:
    python qq_domain_classify.py [域名...]
    python qq_domain_classify.py --help

连接参数走环境变量：`MIHOMO_API`（默认 http://127.0.0.1:9999）、
`MIHOMO_HOST` / `MIHOMO_PORT`、`MIHOMO_SECRET`（必填）。
脚本会临时把 log-level 调到 debug，结束时恢复成 info。
"""
import json, os, socket, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mihomo"))
from mihomo_api import api, dns_query, open_socket, host_header, auth_header

lines = []
lock = threading.Lock()
stop = threading.Event()

# 公网 DNS 上游标记：国内 / 境外
DOMESTIC = ("doh.pub", "dns.alidns.com", "223.5.5.5", "2400:3200::1")
FOREIGN = ("cloudflare-dns.com", "dns.google", "doh.opendns.com")

DEFAULT_DOMAINS = [
    "im.qq.com", "long.qq.com", "misc.qq.com", "webqq.com", "ssl.ptlogin2.qq.com",
    "qmsg.qq.com", "www.qq.com", "user.qpic.cn", "gchat.qpic.cn", "p.qpic.cn",
    "qlogo.cn", "thirdwx.qlogo.cn", "gtimg.cn", "imgtv.qpic.cn", "qmessage.qpic.cn",
    "apdcdn.tc.qq.com", "q.qq.com", "qq.com",
]

USAGE = """用法: python qq_domain_classify.py [域名...]

不给域名时用内置探测清单（腾讯系域名）。
环境变量: MIHOMO_API / MIHOMO_HOST / MIHOMO_PORT / MIHOMO_SECRET
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
                with lock:
                    lines.append(o.get("payload", ""))
            except Exception:
                pass
    s.close()


def classify(domain, mark):
    """在日志里找该域名的上游选择行。"""
    with lock:
        cur = list(lines)
    hits = [p for p in cur if domain in p and "from https://" in p or (domain in p and "from udp://" in p)]
    hits = [p for p in hits if domain in p]
    if not hits:
        return "未知(无日志/命中缓存)"
    used = set()
    for p in hits:
        for u in DOMESTIC:
            if u in p:
                used.add("国内DNS")
        for u in FOREIGN:
            if u in p:
                used.add("境外DNS")
        if "udp://" in p:
            used.add("明文DNS")
    return " + ".join(sorted(used)) if used else "未知"


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    domains = sys.argv[1:] or DEFAULT_DOMAINS
    api("/configs", method="PATCH", body=json.dumps({"log-level": "debug"}).encode(),
        timeout=60, tries=20)
    threading.Thread(target=stream_logs, daemon=True).start()
    time.sleep(1.5)
    print(f"{'域名':24s} {'DNS 通道':22s} 判定")
    for d in domains:
        try:
            dns_query(d)
        except Exception as e:
            print(f"{d:24s} 查询失败 {e}")
            continue
        time.sleep(1.2)
        c = classify(d, None)
        verdict = "在 cn 规则集 → 直连" if "国内DNS" in c else (
            "不在 cn → 走兜底组(代理出口)" if "境外DNS" in c else c)
        print(f"{d:24s} {c:22s} {verdict}")
    stop.set()
    time.sleep(0.5)
    try:
        api("/configs", method="PATCH", body=json.dumps({"log-level": "info"}).encode(),
            timeout=60, tries=20)
    except Exception as e:
        print("恢复日志级别失败:", e)
    return 0


if __name__ == "__main__":
    sys.exit(main())
