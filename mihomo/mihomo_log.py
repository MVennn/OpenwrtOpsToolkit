#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""抓取 mihomo 实时日志（debug 级），用来看 DNS 上游选择与规则命中。

用法:
    python mihomo_log.py <持续秒数> [要触发的域名...]
    python mihomo_log.py --help

连接参数走环境变量：`MIHOMO_API`（默认 http://127.0.0.1:9999）、
`MIHOMO_HOST` / `MIHOMO_PORT`、`MIHOMO_SECRET`（必填）。
脚本会把 log-level 临时调到 debug，结束时恢复成进工具前的原级别（读不到则回落 info）。
"""
import json, os, socket, sys, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mihomo_api import api, dns_query, open_socket, host_header, auth_header

lines = []

USAGE = """用法: python mihomo_log.py <持续秒数> [要触发的域名...]

例: python mihomo_log.py 20 example.com

环境变量: MIHOMO_API / MIHOMO_HOST / MIHOMO_PORT / MIHOMO_SECRET
"""


def stream_logs(stop_at, level="debug"):
    s = open_socket(5)
    req = (f"GET /logs?level={level} HTTP/1.1\r\nHost: {host_header()}\r\n"
           f"Authorization: {auth_header()}\r\nConnection: close\r\n\r\n")
    s.sendall(req.encode())
    buf = b""
    while time.time() < stop_at:
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
            if raw.endswith(b"\r"):
                raw = raw[:-1]
            try:
                obj = json.loads(raw.decode("utf-8", "replace"))
                lines.append((obj.get("type", ""), obj.get("payload", "")))
            except Exception:
                pass
    s.close()


def current_log_level(default="info"):
    """读当前日志级别；读不到就回落 default（=旧版硬编码 info 的行为）。"""
    try:
        cfg = api("/configs", timeout=10, tries=2)   # 只探一次口径，别为一个读值拖慢工具
        if isinstance(cfg, dict):
            lv = cfg.get("log-level") or cfg.get("log_level")
            if isinstance(lv, str) and lv.strip():
                return lv.strip()
    except Exception:
        pass
    return default


def restore_log_level(level):
    print(f"恢复日志级别 -> {level}")
    try:
        api("/configs", method="PATCH", body=json.dumps({"log-level": level}).encode(),
            timeout=60, tries=20)
    except Exception as e:
        print("恢复失败:", e)


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    dur = float(sys.argv[1]) if len(sys.argv) > 1 else 20
    domains = sys.argv[2:]
    orig_level = current_log_level()
    print(f"切换日志级别 -> debug（原级别 {orig_level}）")
    api("/configs", method="PATCH", body=json.dumps({"log-level": "debug"}).encode(),
        timeout=60, tries=20)
    # 恢复动作必须走 finally：Ctrl-C / 任何异常都要把级别改回去，否则设备停在
    # debug，debug 日志持续往 48MB 的 /tmp 里写，顶到 guardian 的 tmpfs 水位
    # 就可能在最糟的时刻触发清理（P1-6）。恢复的是进工具前的原级别。
    try:
        t_end = time.time() + dur
        th = threading.Thread(target=stream_logs, args=(t_end,), daemon=True)
        th.start()
        time.sleep(1.5)
        for d in domains:
            try:
                dns_query(d)
                print("  触发查询:", d)
            except Exception as e:
                print("  查询失败", d, e)
            time.sleep(1.0)
        time.sleep(max(2, t_end - time.time() - 1))
    finally:
        restore_log_level(orig_level)

    print(f"\n=== 抓到的日志 {len(lines)} 行 ===")
    for t, p in lines:
        print(f"[{t}] {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
