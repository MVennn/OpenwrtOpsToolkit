#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用本机已存的 GitLab PAT 配置项目：可见性 / 描述 / 话题 / 头像。

令牌只从本地配置文件读进内存，绝不打印、绝不落盘到别处。
项目清单与参数在本文件顶部的 PROJECTS 里 —— 加新仓时改这里再跑一次。

用法：
    python tools/gitlab-setup.py                 # 按 PROJECTS 全部配置
    python tools/gitlab-setup.py --only OpenwrtConsole
    python tools/gitlab-setup.py --dry-run       # 只看当前状态，不改
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = r"F:\Project"
API = "https://gitlab.com/api/v4"
NAMESPACE = "M.Venn"

CFG_PATHS = [
    # 纯令牌文件优先 —— 它是用户手动更新的落点，且 ACL 收紧到只有本人能读
    (os.path.join(os.path.expanduser("~"), ".config", "gitlab", "token"), "~/.config/gitlab/token"),
    (os.path.join(os.path.expanduser("~"), ".config", "glab-cli", "config.yml"), "glab-cli config"),
]

# 仓名 → 项目配置
PROJECTS = {
 "AX3000TOpenwrt": {
   "visibility": "private",
   "description": "小米 AX3000T 路由器上 OpenWrt 25.12.6 的本体运维：网络守护、开机自启、故障恢复、nftables 规则、配置基线与审计证据。",
   "topics": "openwrt, router, ax3000t, operations, selfhosted",
 },
 "ShellcrashRules": {
   "visibility": "private",
   "description": "ShellCrash / mihomo 的代理与分流：扩展配置、starts 本地补丁、规则生成与审计、链路诊断。",
   "topics": "shellcrash, mihomo, clash, proxy, rules, routing",
 },
 "OpenwrtConsole": {
   "visibility": "public",
   "description": "给任意 OpenWrt 设备用的现代 Web 控制台 —— 替代 LuCI，部署在路由器的 /modern/ 路径下。",
   "topics": "openwrt, luci, dashboard, vue3, typescript, webui",
 },
 "ZcodeAIModels": {
   "visibility": "public",
   "description": "把任意 AI 模型供应商接进 ZCode：模型探测、按成本档分档、思考参数矩阵（以 OpenCode-Go 与 WorkBuddy2API 为例）。",
   "topics": "zcode, llm, model-router, ai-gateway, model-routing, provider",
   # 注：GitLab 会拒绝 'opencode' 这个话题（422「项目无法更新！」，疑为保留词）
   # —— 描述里已写明 OpenCode-Go，话题里就不带了。
 },
 "ClientTriage": {
   "visibility": "public",
   "description": "PC 客户端经代理访问境外服务的排障方法与工具：Chrome LNA、fake-IP 冲突、地区判定、CDP 抓控制台。",
   "topics": "chrome, devtools, proxy, troubleshooting, cdp, lna",
 },
 "OpenwrtOpsToolkit": {
   "visibility": "public",
   "description": "OpenWrt / mihomo 运维工具箱：设备侧守护与离线恢复脚本、mihomo 控制面诊断、站点可达性专项排查。",
   "topics": "openwrt, mihomo, ops, tooling, nftables, diagnostics",
 },
}


def load_token():
    """按优先级找令牌：glab-cli 配置 → ~/.config/gitlab/token。"""
    cands = []
    for path, label in CFG_PATHS:
        if not os.path.exists(path):
            continue
        try:
            raw = open(path, encoding="utf-8").read()
        except OSError:
            continue
        if path.endswith("config.yml"):
            m = re.search(r"^\s*token:\s*(\S+)\s*$", raw, re.M)
            if m:
                cands.append((label, m.group(1).strip()))
        else:
            t = raw.strip()
            if t:
                cands.append((label, t))
    for _label, tok in cands:
        if tok:
            return tok
    return None


def req(method, path, data=None, files=None):
    url = API + path
    headers = {"PRIVATE-TOKEN": TOKEN}
    body = None
    if files:
        boundary = "----ZCodeBoundary7MA4YWxkTrZu0gW"
        buf = []
        for k, v in (data or {}).items():
            buf.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
        for k, (fname, content, ctype) in files.items():
            buf.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"; filename=\"{fname}\"\r\n"
                       f"Content-Type: {ctype}\r\n\r\n".encode() + content + b"\r\n")
        buf.append(f"--{boundary}--\r\n".encode())
        body = b"".join(buf)
        headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
    elif data is not None:
        body = urllib.parse.urlencode(data).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    r = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")[:300]


def pid(path):
    return urllib.parse.quote(path, safe="")


def avatar_for(name):
    """用本仓的 logo 当项目头像。"""
    p = os.path.join(BASE, name, "assets", "logo.png")
    return open(p, "rb").read() if os.path.exists(p) else None


ap = argparse.ArgumentParser()
ap.add_argument("--only", action="append", help="只处理指定仓（可多次）")
ap.add_argument("--dry-run", action="store_true", help="只读，不改")
args = ap.parse_args()

TOKEN = load_token()
if not TOKEN:
    print("  ✗ 没找到 GitLab 令牌。")
    print("     放到 %USERPROFILE%\\.config\\gitlab\\token（一行，无 BOM），")
    print("     或跑 powershell -File \"F:\\Project\\GoldSunEnhance\\.work\\gitlab-token.ps1\"")
    sys.exit(1)

st0, me = req("GET", "/user")
if st0 != 200:
    print(f"  ✗ 令牌无效（HTTP {st0}）：{str(me)[:160]}")
    print()
    print("  令牌可能被吊销了。新建一个（scope 勾 api），然后二选一：")
    print("   A) 复制令牌到剪贴板后运行（令牌不经过对话）：")
    print('      powershell -ExecutionPolicy Bypass -File "F:' + chr(92) + 'Project' + chr(92) + 'GoldSunEnhance' + chr(92) + '.work' + chr(92) + 'gitlab-token.ps1"')
    print("   B) 手动把令牌文本存成 %USERPROFILE%" + chr(92) + ".config" + chr(92) + "gitlab" + chr(92) + "token（一行，无 BOM）")
    sys.exit(1)
print(f"  ✓ 令牌有效：{me.get('username')} (id={me.get('id')})")
print()

targets = {k: v for k, v in PROJECTS.items() if not args.only or k in args.only}
ok = 0
for name, cfg in targets.items():
    st, data = req("GET", f"/projects/{pid(NAMESPACE + '/' + name)}")
    if st != 200:
        print(f"  ✗ {name}: 查不到项目（HTTP {st}）{str(data)[:120]}")
        continue
    pid_ = data["id"]
    cur = data.get("visibility")
    if args.dry_run:
        print(f"  · {name:20} 当前={cur:8} 目标={cfg['visibility']}")
        continue
    st2, d2 = req("PUT", f"/projects/{pid_}", {
        "description": cfg["description"],
        "topics": cfg["topics"],
        "visibility": cfg["visibility"],
    })
    if st2 != 200:
        print(f"  ✗ {name}: 设置失败（HTTP {st2}）{str(d2)[:160]}")
        continue
    av = avatar_for(name)
    if av:
        req("PUT", f"/projects/{pid_}", files={"avatar": ("logo.png", av, "image/png")})
    print(f"  ✓ {name:20} {cur} → {d2.get('visibility')}  (id={pid_})")
    ok += 1

print(f"\n  完成 {ok}/{len(targets)}")
