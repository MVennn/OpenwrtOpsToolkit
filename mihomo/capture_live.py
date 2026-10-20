#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""持续增量抓取 mihomo 日志到文件（每条立即落盘），用于捕捉真实链路。

用法:
    python capture_live.py <输出文件> [持续秒数]
    python capture_live.py --help

连接参数走环境变量：`MIHOMO_API`（默认 http://127.0.0.1:9999）、
`MIHOMO_HOST` / `MIHOMO_PORT`、`MIHOMO_SECRET`（必填）。
"""
import json, os, socket, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mihomo_api import open_socket, host_header, auth_header

USAGE = """用法: python capture_live.py <输出文件> [持续秒数]

例: python capture_live.py ./mihomo-live.log 1200

环境变量: MIHOMO_API / MIHOMO_HOST / MIHOMO_PORT / MIHOMO_SECRET
"""


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    if len(sys.argv) < 2:
        print(USAGE)
        return 1
    out_path = sys.argv[1]
    duration = float(sys.argv[2]) if len(sys.argv) > 2 else 1200
    stop_at = time.time() + duration
    f = open(out_path, "a", encoding="utf-8", buffering=1)
    f.write(f"=== capture start {time.strftime('%F %T')} (duration {duration}s) ===\n")

    s = open_socket(5)
    s.sendall((f"GET /logs?level=debug HTTP/1.1\r\nHost: {host_header()}\r\n"
               f"Authorization: {auth_header()}\r\nConnection: close\r\n\r\n").encode())
    buf = b""
    n = 0
    while time.time() < stop_at:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            continue
        except Exception as e:
            f.write(f"[capture error] {e}\n")
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
                f.write(f"[{o.get('type','')}] {o.get('payload','')}\n")
                n += 1
            except Exception:
                pass
    f.write(f"=== capture end, {n} lines ===\n")
    f.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
