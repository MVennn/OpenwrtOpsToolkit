#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""【腾讯系 CDN 专项】QUIC 能力探测。

方法：发送一个版本号无效的 QUIC 长首部包（grease version）。
支持 QUIC 的服务器会回一个明文的 Version Negotiation 包（version=0, 首字节高位=1）。

为什么值得测：透明代理（Redir）通常只代理 TCP，UDP 直出 ——
服务器不支持 QUIC、或客户端被强制降级到 HTTP/3 时，现象会一样，
但根因完全不同。

用法:
    python quic_probe.py [域名...]
    python quic_probe.py --help

默认探测清单含腾讯系 CDN 与两个对照站点；可用环境变量 `QUIC_PROBE_HOSTS`
（`标签=域名` 逗号分隔）覆盖。
"""
import os, socket, sys, time

DEFAULT_TARGETS = [
    ("bilibili (对照,国内支持H3)", "www.bilibili.com"),
    ("QQ 聊天图片 CDN", "gchat.qpic.cn"),
    ("QQ 图片 CDN", "p.qpic.cn"),
    ("QQ 头像 CDN", "thirdwx.qlogo.cn"),
    ("QQ 顶层", "qpic.cn"),
    ("Cloudflare (对照,国外支持H3)", "cloudflare-dns.com"),
]

USAGE = """用法: python quic_probe.py [域名...]

环境变量: QUIC_PROBE_HOSTS（标签=域名，逗号分隔）
"""


def probe(host, ip, port=443, timeout=3.0):
    pkt = bytearray()
    pkt += bytes([0xC0])                       # 长首部 + fixed bit + 4 字节包号
    pkt += b"\x0a\x0a\x0a\x0a"                 # 非法版本号 -> 触发版本协商
    dcid = os.urandom(8)
    pkt += bytes([len(dcid)]) + dcid
    scid = os.urandom(8)
    pkt += bytes([len(scid)]) + scid
    pkt += os.urandom(1200 - len(pkt))         # 补到 1200 字节最小包长
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    t0 = time.time()
    try:
        s.sendto(bytes(pkt), (ip, port))
        data, _ = s.recvfrom(2048)
        rtt = (time.time() - t0) * 1000
        if len(data) > 0 and (data[0] & 0x80) and data[1:5] == b"\x00\x00\x00\x00":
            return f"支持 QUIC (Version Negotiation, rtt={rtt:.0f}ms)"
        if len(data) > 0 and (data[0] & 0x80):
            ver = data[1:5].hex()
            return f"有 QUIC 响应但非版本协商 (ver=0x{ver}, rtt={rtt:.0f}ms)"
        return f"有响应但非 QUIC ({len(data)} 字节, rtt={rtt:.0f}ms)"
    except socket.timeout:
        return "无响应 (UDP 被丢或不支持 QUIC)"
    except Exception as e:
        return f"ERR {type(e).__name__}"
    finally:
        s.close()


def _targets():
    raw = os.environ.get("QUIC_PROBE_HOSTS", "").strip()
    if not raw:
        return DEFAULT_TARGETS
    out = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        if "=" in item:
            label, host = item.split("=", 1)
        else:
            label, host = item, item
        out.append((label.strip(), host.strip()))
    return out


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    if len(sys.argv) > 1:
        targets = [(h, h) for h in sys.argv[1:]]
    else:
        targets = _targets()
    for label, host in targets:
        try:
            ip = socket.gethostbyname(host)
        except Exception as e:
            print(f"{label:32s} {host:24s} 解析失败 {e}")
            continue
        print(f"{label:32s} {host:24s} {ip:16s} -> {probe(host, ip)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
