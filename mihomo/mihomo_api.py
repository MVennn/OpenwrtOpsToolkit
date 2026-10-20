#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mihomo 控制 API 客户端（IPv4/IPv6 自动选路 + 多次重试 + chunked 解码）。

控制台默认开着 secret，所以所有请求都带 Authorization 头；
secret 从环境变量 `MIHOMO_SECRET` 读 —— **缺失就报错退出**
（宁可当场报错，也不要拿空 secret 去换一个含义不明的 401）。

连接参数（全部走环境变量，不写死任何地址）：

| 变量 | 含义 | 默认 |
|---|---|---|
| `MIHOMO_API` | 控制 API 基址 | `http://127.0.0.1:9999` |
| `MIHOMO_HOST` | 主机（IPv4 / IPv6 字面量均可），优先于 `MIHOMO_API` | 取自 `MIHOMO_API` |
| `MIHOMO_PORT` | 端口，优先于 `MIHOMO_API` | 取自 `MIHOMO_API` |
| `MIHOMO_SECRET` | 控制台 secret | **必填** |

命令行：
    python mihomo_api.py summary
    python mihomo_api.py proxies [组名...]
    python mihomo_api.py rulestats
    python mihomo_api.py conns
    python mihomo_api.py dns [域名...]
    python mihomo_api.py delay <URL> [组名...]
    python mihomo_api.py raw <路径>
"""
import json, os, socket, sys, time, urllib.parse

DEFAULT_API = "http://127.0.0.1:9999"


def _api_default():
    """从 MIHOMO_API 解析出 (host, port)；解析不了就用本机默认值。"""
    raw = os.environ.get("MIHOMO_API", "").strip() or DEFAULT_API
    if "://" not in raw:
        raw = "http://" + raw
    try:
        p = urllib.parse.urlparse(raw)
        host = p.hostname or "127.0.0.1"
        port = p.port or (443 if p.scheme == "https" else 9999)
        return host, port
    except Exception:
        return "127.0.0.1", 9999


_dh, _dp = _api_default()
HOST = os.environ.get("MIHOMO_HOST", "").strip() or _dh
PORT = int(os.environ.get("MIHOMO_PORT", "").strip() or _dp)

# mihomo 控制台 secret 不写在源码里：只从环境变量读
SECRET = os.environ.get("MIHOMO_SECRET", "").strip()


def _secret():
    """取 mihomo 控制台 secret；未提供时立刻报错，避免静默 Unauthorized。"""
    s = os.environ.get("MIHOMO_SECRET", "").strip()
    if not s:
        raise RuntimeError(
            "缺少环境变量 MIHOMO_SECRET（mihomo 控制台 secret）"
        )
    return s


def host_header():
    """Host 头：IPv6 字面量必须带方括号。"""
    h = f"[{HOST}]" if ":" in HOST else HOST
    return f"{h}:{PORT}"


def auth_header():
    """Authorization 头的值。"""
    return f"Bearer {_secret()}"


def open_socket(timeout=20):
    """按 MIHOMO_HOST 的地址族建连控制 API，返回已连接的 socket。"""
    fam = socket.AF_INET6 if ":" in HOST else socket.AF_INET
    s = socket.socket(fam, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((HOST, PORT))
    return s


def _raw_request(method, path, body=None, timeout=20):
    s = open_socket(timeout)
    try:
        hdr = (f"{method} {path} HTTP/1.1\r\nHost: {host_header()}\r\n"
               f"Authorization: {auth_header()}\r\nConnection: close\r\n")
        if body is not None:
            hdr += "Content-Type: application/json\r\nContent-Length: %d\r\n" % len(body)
        hdr += "\r\n"
        s.sendall(hdr.encode() + (body or b""))
        buf = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        head, _, payload = buf.partition(b"\r\n\r\n")
        status = head.split(b"\r\n")[0].decode(errors="replace")
        if b"chunked" in head.lower():
            out = b""
            while payload:
                line, _, rest = payload.partition(b"\r\n")
                try:
                    n = int(line.strip().split(b";")[0], 16)
                except ValueError:
                    break
                if n == 0:
                    break
                out += rest[:n]
                payload = rest[n + 2:]
            payload = out
        return status, payload
    finally:
        s.close()


def api(path, method="GET", body=None, tries=12, timeout=15):
    """带重试的 API 调用。"""
    _secret()   # 缺 secret 立刻明确报错，不做无谓重试
    last = None
    for i in range(tries):
        try:
            status, payload = _raw_request(method, path, body, timeout)
            code = status.split(" ")[1] if " " in status else ""
            if code.startswith("2"):
                if not payload.strip():
                    return {"_status": code}
                try:
                    return json.loads(payload.decode("utf-8", "replace"))
                except Exception:
                    return payload.decode("utf-8", "replace")
            last = status
        except Exception as e:
            last = type(e).__name__
        time.sleep(0.6)
    raise RuntimeError(f"API failed after {tries} tries: {path} ({last})")


def dns_query(name, rtype="A"):
    q = urllib.parse.urlencode({"name": name, "type": rtype})
    return api(f"/dns/query?{q}")


def _env_list(name, default):
    raw = os.environ.get(name, "").strip()
    if not raw:
        return list(default)
    return [x.strip() for x in raw.split(",") if x.strip()]


# ---- 命令行各子命令的默认值（全部可用环境变量覆盖） ----
# 策略组名：环境变量 MIHOMO_PROBE_GROUPS（逗号分隔），默认是通用占位符
DEFAULT_GROUPS = _env_list("MIHOMO_PROBE_GROUPS", ["GROUP_A", "GROUP_B", "GROUP_C"])
# summary 里额外关注的 payload 子串：MIHOMO_RULE_KEYWORDS（逗号分隔），默认不过滤
RULE_KEYWORDS = [k.lower() for k in _env_list("MIHOMO_RULE_KEYWORDS", [])]
# rulestats 里关注的规则集名（精确匹配）：MIHOMO_RULE_SETS，默认 cn
RULE_SETS = [k.lower() for k in _env_list("MIHOMO_RULE_SETS", ["cn"])]
# conns 里关注的连接域名子串：MIHOMO_CONN_KEYWORDS，默认全打
CONN_KEYWORDS = [k.lower() for k in _env_list("MIHOMO_CONN_KEYWORDS", [])]

USAGE = """用法: python mihomo_api.py <子命令> [参数...]

  summary                 概览：版本 / 内核参数 / 规则统计
  proxies [组名...]       打印策略组状态（组名默认取 $MIHOMO_PROBE_GROUPS）
  rulestats               规则类型分布与末尾若干条
  conns                  当前连接快照（按 $MIHOMO_CONN_KEYWORDS 过滤）
  dns [域名...]           通过 mihomo 解析域名（默认 $MIHOMO_RULE_DNS_HOSTS）
  delay <URL> [组名...]   测指定 URL 经各组的握手延迟
  raw <路径>              打印任意 API 路径的原始 JSON

环境变量: MIHOMO_API / MIHOMO_HOST / MIHOMO_PORT / MIHOMO_SECRET
"""


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    cmd = sys.argv[1]
    if cmd == "summary":
        v = api("/version"); print("version:", v)
        cfg = api("/configs")
        print("dns.enable:", cfg.get("dns", {}).get("enable") if isinstance(cfg, dict) else cfg)
        for k in ("mode", "ipv6", "log-level", "mixed-port", "port", "redir-port", "tproxy-port"):
            if isinstance(cfg, dict):
                print(f"  {k}: {cfg.get(k)}")
        rules = api("/rules")
        print("rules total:", len(rules))
        for r in rules:
            if not isinstance(r, dict):
                continue
            t = (r.get("type") or "").upper()
            pay = str(r.get("payload") or "")
            if t in ("RULE-SET", "MATCH", "GEOSITE", "GEOIP") or \
                    any(k in pay.lower() for k in RULE_KEYWORDS):
                print(f"  [{r.get('type')}] {pay} -> {r.get('proxy')}   (size={r.get('size')})")
    elif cmd == "proxies":
        for g in (sys.argv[2:] or DEFAULT_GROUPS):
            try:
                o = api("/proxies/" + urllib.parse.quote(g), timeout=60, tries=20)
                if isinstance(o, dict):
                    print(f"{g:24s} type={o.get('type'):9s} now={o.get('now')}  udp={o.get('udp')}  hist={len(o.get('history') or [])}")
                else:
                    print(f"{g:24s} -> {o}")
            except Exception as e:
                print(f"{g:24s} -> ERR {e}")
    elif cmd == "rulestats":
        rules = api("/rules", timeout=90, tries=20)
        print("rules total:", len(rules))
        from collections import Counter
        c = Counter((r.get("type") if isinstance(r, dict) else "?") for r in rules)
        print("类型分布:", dict(c))
        for r in rules[-8:]:
            if isinstance(r, dict):
                print("  末尾:", r.get("type"), "|", str(r.get("payload"))[:60], "->", r.get("proxy"))
        hits = [r for r in rules if isinstance(r, dict)
                and str(r.get("payload", "")).lower() in RULE_SETS]
        for r in hits[:20]:
            print("  命中候选:", r.get("type"), "|", str(r.get("payload"))[:40], "->", r.get("proxy"))
    elif cmd == "conns":
        d = api("/connections")
        cs = d.get("connections", [])
        print("总连接数:", len(cs))
        for c in cs:
            m = c.get("metadata", {})
            h = (m.get("host") or "") + " " + (m.get("sniffHost") or "")
            if not CONN_KEYWORDS or any(k in h.lower() for k in CONN_KEYWORDS):
                print("host=%-36s rule=%-16s payload=%-22s chains=%s src=%s" % (
                    m.get("host"), c.get("rule"), str(c.get("rulePayload"))[:22], c.get("chains"), m.get("sourceIP")))
    elif cmd == "dns":
        hosts = _env_list("MIHOMO_RULE_DNS_HOSTS", ["example.com"])
        for h in (sys.argv[2:] or hosts):
            try:
                print(f"{h:20s} -> {dns_query(h)}")
            except Exception as e:
                print(f"{h:20s} -> ERR {e}")
    elif cmd == "delay":
        url = sys.argv[2]
        for g in (sys.argv[3:] or DEFAULT_GROUPS):
            path = f"/proxies/{urllib.parse.quote(g)}/delay?timeout=15000&url={urllib.parse.quote(url, safe='')}"
            t0 = time.time()
            try:
                r = api(path, timeout=60, tries=20)
                print(f"{g:16s} {url}  -> {r}  (API 往返 {time.time()-t0:.1f}s)")
            except Exception as e:
                print(f"{g:16s} {url}  -> ERR {e}")
    elif cmd == "raw":
        print(json.dumps(api(sys.argv[2]), ensure_ascii=False, indent=1)[:4000])
    else:
        print(USAGE)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
