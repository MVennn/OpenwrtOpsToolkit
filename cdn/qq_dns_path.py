#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""【腾讯系 CDN 专项】判定某个域名是否落在路由器的 cn 规则集内。

原理：路由器的 DNS nameserver-policy 通常把 `rule-set:cn` 指向国内 DNS（alidns / doh.pub），
其余域名指向境外 DoH（经代理出去）。方法：解析域名后观察路由器**新产生**的 DNS 上游连接。

用法:
    python qq_dns_path.py [域名...]
    python qq_dns_path.py --help

连接参数走环境变量：`MIHOMO_API`（默认 http://127.0.0.1:9999）、
`MIHOMO_HOST` / `MIHOMO_PORT`、`MIHOMO_SECRET`（必填）。

判定的是「域名落在哪条 DNS 通道上」，域名清单就是本工具的探测对象。
"""
import os
import sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mihomo"))
from mihomo_api import api, dns_query

# 常见 DNS 上游标记（公网 DNS 服务商的地址与域名）
DNS_MARKS = ("223.5.5.5", "120.53.53.53", "cloudflare-dns.com", "dns.google",
             "doh.opendns.com", "dns.alidns.com", "doh.pub")

DEFAULT_TARGETS = ["www.baidu.com", "qpic.cn", "gchat.qpic.cn", "p.qpic.cn",
                   "qlogo.cn", "gtimg.cn", "example.com", "www.google.com"]

USAGE = """用法: python qq_dns_path.py [域名...]

不给域名时用内置探测清单（含腾讯系与对照域名）。
环境变量: MIHOMO_API / MIHOMO_HOST / MIHOMO_PORT / MIHOMO_SECRET
"""


def snap():
    d = api("/connections", timeout=90, tries=25)
    out = {}
    for c in d.get("connections", []):
        m = c.get("metadata", {})
        key = (m.get("host") or "", m.get("destinationIP") or "", m.get("destinationPort") or "")
        if any(k in (key[0] + key[1]) for k in DNS_MARKS):
            out[key] = c.get("start")
    return out


def classify(host, before, after):
    new = {k: v for k, v in after.items() if k not in before or before[k] != v}
    if not new:
        return "无新增 DNS 上游连接(可能命中缓存)"
    tags = []
    for (h, ip, port) in new:
        who = ip or h
        if who in ("223.5.5.5", "120.53.53.53", "dns.alidns.com", "doh.pub"):
            tags.append("国内DNS")
        else:
            tags.append(f"境外DNS({who})")
    return " + ".join(sorted(set(tags)))


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    targets = sys.argv[1:] or DEFAULT_TARGETS
    print("域名 -> 路由器实际使用的上游 DNS 通道")
    for t in targets:
        before = snap()
        try:
            dns_query(t)
        except Exception as e:
            print(f"{t:20s} 查询失败 {e}")
            continue
        time.sleep(2.0)
        after = snap()
        print(f"{t:20s} -> {classify(t, before, after)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
