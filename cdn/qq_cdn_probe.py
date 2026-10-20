#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""【腾讯系 CDN 专项】QQ / 微信图片 CDN 的连通性与时延探测。

区分 DNS、TCP、TLS、HTTP 各阶段耗时 —— 「打不开」到底是解析不了、
连不上、还是握手卡住，靠这一段就分开了。

用法:
    python qq_cdn_probe.py [dns|probe|all]
    python qq_cdn_probe.py --help

域名与 DNS 服务器可用环境变量覆盖：
- `QQ_CDN_HOSTS`（逗号分隔，默认腾讯系图片域名清单）
- `QQ_CDN_RESOLVERS`（逗号分隔，默认四个公共 DNS）

本工具是**站点专项**工具：域名清单就是它的探测对象，不是配置项。
"""
import os, socket, ssl, time, sys

DEFAULT_HOSTS = [
    "qpic.cn", "user.qpic.cn", "qmessage.qpic.cn", "imgtv.qpic.cn",
    "qlogo.cn", "thirdwx.qlogo.cn", "gtimg.cn", "inews.gtimg.cn",
    "qzonetag.gtimg.cn", "imgcache.qq.com",
]
DEFAULT_RESOLVERS = ["119.29.29.29", "114.114.114.114", "223.5.5.5", "1.1.1.1"]

USAGE = """用法: python qq_cdn_probe.py [dns|probe|all]

  dns    只比各 DNS 服务器的解析结果
  probe  用系统 DNS 解析后逐 IP 试 TCP/TLS/HTTP
  all    两段都跑（默认）
"""


def _split_env(name, default):
    raw = os.environ.get(name, "").strip()
    if not raw:
        return list(default)
    return [x.strip() for x in raw.split(",") if x.strip()]


def resolve(host, server=None, timeout=4.0):
    """用指定 DNS 服务器解析，返回 IPv4 列表。"""
    q = bytes([len(host)] + [ord(c) for c in host]) + b"\x00"
    pkt = b"\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + q + b"\x00\x01\x00\x01"
    out = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(timeout)
        s.sendto(pkt, (server, 53))
        data, _ = s.recvfrom(2048)
        ancount = int.from_bytes(data[6:8], "big")
        i = 12
        while i < len(data) and data[i] != 0:
            i += 1 + data[i]
        i += 1 + 4  # qname 结束 + QTYPE(2) + QCLASS(2)
        for _ in range(ancount):
            if data[i] & 0xC0 == 0xC0:
                i += 2
            else:
                while data[i] != 0:
                    i += 1 + data[i]
                i += 1
            rtype = int.from_bytes(data[i:i+2], "big")
            i += 8  # TYPE(2) + CLASS(2) + TTL(4)
            rdlen = int.from_bytes(data[i:i+2], "big")
            i += 2
            if rtype == 1 and rdlen == 4:
                out.append(".".join(str(b) for b in data[i:i+4]))
            i += rdlen
        s.close()
    except Exception as e:
        return ["ERR:" + type(e).__name__]
    return out or ["NODATA"]


def probe(host, ip, port=443):
    ctx = ssl.create_default_context()
    t0 = time.time()
    try:
        s = socket.create_connection((ip, port), timeout=5)
    except Exception as e:
        return {"ip": ip, "tcp": None, "tls": None, "http": None, "err": "TCP " + type(e).__name__}
    t1 = time.time()
    try:
        s.settimeout(6)
        ss = ctx.wrap_socket(s, server_hostname=host)
        t2 = time.time()
        req = f"GET / HTTP/1.1\r\nHost: {host}\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n"
        ss.sendall(req.encode())
        buf = ss.recv(200)
        t3 = time.time()
        line = buf.split(b"\r\n")[0].decode(errors="replace")
        ss.close()
        return {"ip": ip, "tcp": round(t1-t0, 3), "tls": round(t2-t1, 3),
                "http": round(t3-t2, 3), "status": line, "err": None}
    except Exception as e:
        return {"ip": ip, "tcp": round(t1-t0, 3), "tls": None, "http": None, "err": "TLS " + type(e).__name__}


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    hosts = _split_env("QQ_CDN_HOSTS", DEFAULT_HOSTS)
    resolvers = _split_env("QQ_CDN_RESOLVERS", DEFAULT_RESOLVERS)
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"

    if mode in ("dns", "all"):
        print("=== DNS 解析对比 ===")
        for h in hosts:
            row = []
            for r in resolvers:
                ips = resolve(h, r)
                row.append(f"{r}={'/'.join(ips[:3])}")
            print(f"{h:22s} " + " | ".join(row))

    if mode in ("probe", "all"):
        print("\n=== 连接探测 (系统 DNS 解析后逐 IP 试) ===")
        for h in hosts:
            ips = [ip for ip in resolve(h, "223.5.5.5") if not ip.startswith(("ERR", "NODATA"))]
            if not ips:
                print(f"{h:22s} 解析失败")
                continue
            for ip in ips[:3]:
                r = probe(h, ip)
                if r["err"]:
                    print(f"{h:22s} {ip:16s} FAIL {r['err']}")
                else:
                    print(f"{h:22s} {ip:16s} tcp={r['tcp']}s tls={r['tls']}s http={r['http']}s  {r['status']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
