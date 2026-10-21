#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用本机已存的 GitHub token 配置仓库：可见性 / 描述 / 话题。

令牌只从环境变量或本机 git 凭据读进内存，绝不打印、绝不落盘到别处。
仓库清单与参数在本文件顶部的 PROJECTS 里 —— 加新仓时改这里再跑一次。

用法：
    python tools/github-setup.py                 # 按 PROJECTS 全部配置
    python tools/github-setup.py --only OpenwrtConsole
    python tools/github-setup.py --dry-run       # 只看当前状态，不改
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
OWNER = "MVennn"

# 仓名 → 仓库配置
PROJECTS = {
 "AX3000TOpenwrt": {
   "private": True,
   "description": "小米 AX3000T 路由器上 OpenWrt 25.12.6 的本体运维：网络守护、开机自启、故障恢复、nftables 规则、配置基线与审计证据。",
   "topics": ["openwrt", "router", "ax3000t", "operations", "selfhosted"],
 },
 "ShellcrashRules": {
   "private": True,
   "description": "ShellCrash / mihomo 的代理与分流：扩展配置、starts 本地补丁、规则生成与审计、链路诊断。",
   "topics": ["shellcrash", "mihomo", "clash", "proxy", "rules", "routing"],
 },
 "OpenwrtConsole": {
   "private": False,
   "description": "给任意 OpenWrt 设备用的现代 Web 控制台 —— 替代 LuCI，部署在路由器的 /modern/ 路径下。",
   "topics": ["openwrt", "luci", "dashboard", "vue3", "typescript", "webui"],
 },
 "ZcodeAIModels": {
   "private": False,
   "description": "把任意 AI 模型供应商接进 ZCode：模型探测、按成本档分档、思考参数矩阵（以 OpenCode-Go 与 WorkBuddy2API 为例）。",
   "topics": ["zcode", "llm", "model-router", "ai-gateway", "model-routing", "provider"],
 },
 "ClientTriage": {
   "private": False,
   "description": "PC 客户端经代理访问境外服务的排障方法与工具：Chrome LNA、fake-IP 冲突、地区判定、CDP 抓控制台。",
   "topics": ["chrome", "devtools", "proxy", "troubleshooting", "cdp", "lna"],
 },
 "OpenwrtOpsToolkit": {
   "private": False,
   "description": "OpenWrt / mihomo 运维工具箱：设备侧守护与离线恢复脚本、mihomo 控制面诊断、站点可达性专项排查。",
   "topics": ["openwrt", "mihomo", "ops", "tooling", "nftables", "diagnostics"],
 },
}


def load_token():
    """按优先级找令牌：GS_GITHUB_TOKEN → GH_TOKEN → git credential fill。"""
    for key in ("GS_GITHUB_TOKEN", "GH_TOKEN"):
        tok = os.environ.get(key, "").strip()
        if tok:
            return tok
    try:
        out = subprocess.run(
            ["git", "credential", "fill"],
            input="protocol=https\nhost=github.com\n\n",
            capture_output=True, text=True, check=True, timeout=20,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        if line.startswith("password="):
            tok = line.split("=", 1)[1].strip()
            if tok:
                return tok
    return None


def req(method, path, data=None):
    body = json.dumps(data).encode("utf-8") if data is not None else None
    headers = {
        "Authorization": "Bearer " + TOKEN,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if body is not None:
        headers["Content-Type"] = "application/json; charset=utf-8"
    r = urllib.request.Request(API + path, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")[:300]


ap = argparse.ArgumentParser()
ap.add_argument("--only", action="append", help="只处理指定仓（可多次）")
ap.add_argument("--dry-run", action="store_true", help="只读，不改")
args = ap.parse_args()

TOKEN = load_token()
if not TOKEN:
    print("  ✗ 没找到 GitHub 令牌。")
    print("     设置 GS_GITHUB_TOKEN 或 GH_TOKEN，或让 git 凭据管理器存好 github.com 的 PAT。")
    sys.exit(1)

st0, me = req("GET", "/user")
if st0 != 200:
    print(f"  ✗ 令牌无效（HTTP {st0}）：{str(me)[:160]}")
    sys.exit(1)
print(f"  ✓ 令牌有效：{me.get('login')} (id={me.get('id')})")
print()

targets = {k: v for k, v in PROJECTS.items() if not args.only or k in args.only}
ok = 0
for name, cfg in targets.items():
    st, data = req("GET", f"/repos/{OWNER}/{name}")
    if st != 200:
        print(f"  ✗ {name}: 查不到仓库（HTTP {st}）{str(data)[:120]}")
        continue
    cur = "private" if data.get("private") else "public"
    target = "private" if cfg["private"] else "public"
    if args.dry_run:
        print(f"  · {name:20} 当前={cur:8} 目标={target}")
        continue
    st2, d2 = req("PATCH", f"/repos/{OWNER}/{name}", {
        "description": cfg["description"],
        "private": cfg["private"],
    })
    if st2 != 200:
        print(f"  ✗ {name}: 设置失败（HTTP {st2}）{str(d2)[:160]}")
        continue
    st3, d3 = req("PUT", f"/repos/{OWNER}/{name}/topics", {"names": cfg["topics"]})
    if st3 != 200:
        print(f"  ⚠ {name}: 描述已更新，话题失败（HTTP {st3}）{str(d3)[:120]}")
    print(f"  ✓ {name:20} {cur} → {target}  （描述 + {len(cfg['topics'])} 个话题）")
    ok += 1

print(f"\n  完成 {ok}/{len(targets)}")
