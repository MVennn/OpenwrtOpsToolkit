#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mihomo（Clash.Meta / ShellCrash）规则审计：

- 按模板顺序把内联规则分回上游列表
- 按「先匹配先赢」计算每条域名规则的真实生效目标
- 统计精确冲突、顺序遮蔽、广告误伤、代表性域名归类

用法:
    python rule_audit.py [config.yaml] [proxies.json] [lists目录] [REPORT.md] [geosite:cn文本列表]
    python rule_audit.py --help

依赖：PyYAML（`pip install pyyaml`）。

**策略组名不写死在脚本里** —— 全部走环境变量，默认是通用占位符：

| 环境变量 | 含义 | 默认 |
|---|---|---|
| `AUDIT_DIRECT_GROUP` | 直连组 | `DIRECT_GROUP` |
| `AUDIT_AD_GROUP` | 广告拦截组 | `AD_GROUP` |
| `AUDIT_AI_GROUPS` | AI 组（逗号分隔，可多个） | `AI_GROUP` |
| `AUDIT_FCM_GROUP` | 推送组 | `FCM_GROUP` |
| `AUDIT_TELEGRAM_GROUP` | 电报组 | `TELEGRAM_GROUP` |
| `AUDIT_NETFLIX_GROUP` | 流媒体组（Netflix） | `NETFLIX_GROUP` |
| `AUDIT_DISNEY_GROUP` | 流媒体组（Disney+） | `DISNEY_GROUP` |
| `AUDIT_MS_GROUP` | 微软服务组 | `MS_GROUP` |
| `AUDIT_APPLE_GROUP` | 苹果服务组 | `APPLE_GROUP` |
"""
import sys, os, glob, json, re, collections

try:
    import yaml
except ImportError:  # 缺依赖时给一句能照做的提示，而不是裸 ImportError
    raise SystemExit(
        "缺少依赖 PyYAML：pip install pyyaml\n"
        "（本工具要解析 mihomo 的 config.yaml；只想看运行期规则的话用 scan_rules.py）"
    )


def _env_list(name, default):
    raw = os.environ.get(name, "").strip()
    if not raw:
        return list(default)
    return [x.strip() for x in raw.split(",") if x.strip()]


# ---- 策略组名（环境变量覆盖，默认通用占位符） ----
DIRECT_GROUP = os.environ.get("AUDIT_DIRECT_GROUP", "DIRECT_GROUP").strip()
AD_GROUP = os.environ.get("AUDIT_AD_GROUP", "AD_GROUP").strip()
AI_GROUPS = _env_list("AUDIT_AI_GROUPS", ["AI_GROUP"])
FCM_GROUP = os.environ.get("AUDIT_FCM_GROUP", "FCM_GROUP").strip()
TELEGRAM_GROUP = os.environ.get("AUDIT_TELEGRAM_GROUP", "TELEGRAM_GROUP").strip()
NETFLIX_GROUP = os.environ.get("AUDIT_NETFLIX_GROUP", "NETFLIX_GROUP").strip()
DISNEY_GROUP = os.environ.get("AUDIT_DISNEY_GROUP", "DISNEY_GROUP").strip()
MS_GROUP = os.environ.get("AUDIT_MS_GROUP", "MS_GROUP").strip()
APPLE_GROUP = os.environ.get("AUDIT_APPLE_GROUP", "APPLE_GROUP").strip()

USAGE = """用法: python rule_audit.py [config.yaml] [proxies.json] [lists目录] [REPORT.md] [geosite:cn文本列表]

例: python rule_audit.py config.yaml proxies.json lists REPORT.md

环境变量（策略组名）:
  AUDIT_DIRECT_GROUP   直连组            默认 DIRECT_GROUP
  AUDIT_AD_GROUP       广告拦截组        默认 AD_GROUP
  AUDIT_AI_GROUPS      AI 组（逗号分隔） 默认 AI_GROUP
  AUDIT_FCM_GROUP      推送组            默认 FCM_GROUP
  AUDIT_TELEGRAM_GROUP 电报组            默认 TELEGRAM_GROUP
  AUDIT_NETFLIX_GROUP  Netflix 组        默认 NETFLIX_GROUP
  AUDIT_DISNEY_GROUP   Disney+ 组        默认 DISNEY_GROUP
  AUDIT_MS_GROUP       微软服务组        默认 MS_GROUP
  AUDIT_APPLE_GROUP    苹果服务组        默认 APPLE_GROUP
"""

if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help", "help"):
    print(USAGE)
    sys.exit(0)

CONFIG = sys.argv[1] if len(sys.argv) > 1 else "config.yaml"
PROXIES = sys.argv[2] if len(sys.argv) > 2 else "proxies.json"
LISTDIR = sys.argv[3] if len(sys.argv) > 3 else "lists"
REPORT = sys.argv[4] if len(sys.argv) > 4 else "REPORT.md"
# findings.json 跟着报告放同目录：从仓根跑时不要写脏工作区，
# 从只读目录跑时也不至于直接抛 PermissionError。
FINDINGS = os.path.join(os.path.dirname(os.path.abspath(REPORT)), "findings.json")

# ---------- 解析 ----------
def parse_gen(s):
    p = [x.strip() for x in s.split(",")]
    t = p[0].upper()
    if t in ("MATCH", "FINAL"):
        return {"type": "MATCH", "value": "", "target": p[1] if len(p) > 1 else "", "opts": p[2:]}
    if len(p) < 3:
        return {"type": t, "value": p[1] if len(p) > 1 else "", "target": "", "opts": []}
    return {"type": t, "value": p[1], "target": p[2], "opts": p[3:]}

def parse_list_line(s):
    s = s.strip()
    if not s or s.startswith("#"):
        return None
    p = [x.strip() for x in s.split(",")]
    t = p[0].upper()
    if t in ("MATCH", "FINAL"):
        return ("MATCH", "", "FINAL")
    if len(p) < 2:
        return None
    val = p[1].lower() if t.startswith("DOMAIN") else p[1]
    return (t, val, p[2] if len(p) > 2 else "")

def load_lists():
    out = []
    for f in sorted(glob.glob(os.path.join(LISTDIR, "*.list"))):
        rules = [r for r in (parse_list_line(x) for x in open(f, encoding="utf-8", errors="replace")) if r]
        out.append((os.path.basename(f), rules))
    return out

d = yaml.safe_load(open(CONFIG, encoding="utf-8"))
rules = [parse_gen(x) for x in d["rules"]]
lists = load_lists()

# 可选：geosite:cn 文本列表，用于模拟 RULE-SET,cn
CNLIST = sys.argv[5] if len(sys.argv) > 5 else ""
cn_suffix = set()
if CNLIST and os.path.exists(CNLIST):
    for ln in open(CNLIST, encoding="utf-8", errors="replace"):
        ln = ln.strip()
        if ln.startswith("+.") or ln.startswith("*."):
            cn_suffix.add(ln[2:].lower())
        elif ln and not ln.startswith("#"):
            cn_suffix.add(ln.lower())
def in_cn(host):
    h = host.lower().rstrip(".")
    labels = h.split(".")
    for k in range(len(labels)):
        if ".".join(labels[k:]) in cn_suffix:
            return True
    return False

# ---------- 分段：按模板顺序，用每段首条规则定位 ----------
def find_sections():
    starts = []
    cursor = 0
    for idx, (name, lr) in enumerate(lists):
        first = lr[0][:2] if lr else None
        expected = cursor
        lo = max(0, expected - 250)
        hi = min(len(rules), expected + 400)
        cand = None
        for i in range(lo, hi):
            if (rules[i]["type"], rules[i]["value"].lower() if rules[i]["type"].startswith("DOMAIN") else rules[i]["value"]) == first:
                cand = i
                break
        if cand is None:
            for i in range(cursor, len(rules)):
                if (rules[i]["type"], rules[i]["value"].lower() if rules[i]["type"].startswith("DOMAIN") else rules[i]["value"]) == first:
                    cand = i
                    break
        starts.append((name, len(lr), cand))
        if cand is not None:
            cursor = cand + len(lr)
    sections = []
    for i, (name, ln, s) in enumerate(starts):
        e = starts[i + 1][2] if i + 1 < len(starts) else len(rules)
        if s is None:
            continue
        sections.append({"name": name, "start": s, "end": e, "list_count": ln})
    if sections and sections[0]["start"] > 0:
        sections.insert(0, {"name": "00_custom (前置自定义规则)", "start": 0, "end": sections[0]["start"], "list_count": sections[0]["start"]})
    return sections

sections = find_sections()
def sec_of(i):
    for s in sections:
        if s["start"] <= i < s["end"]:
            return s["name"]
    return "?"

# ---------- 统计 ----------
type_counts = collections.Counter(r["type"] for r in rules)
target_counts = collections.Counter(r["target"] for r in rules)
domain_rules = [(i, r) for i, r in enumerate(rules) if r["type"] in ("DOMAIN", "DOMAIN-SUFFIX")]
kw_rules = [(i, r) for i, r in enumerate(rules) if r["type"] == "DOMAIN-KEYWORD"]

# 精确冲突
occ = collections.defaultdict(list)
for i, r in enumerate(rules):
    if r["type"] in ("DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD"):
        key = (r["type"], r["value"].lower() if r["type"].startswith("DOMAIN") else r["value"])
        occ[key].append((i, r["target"], sec_of(i)))
exact_conflicts = []
for key, lst in occ.items():
    ts = {x[1] for x in lst}
    if len(ts) > 1:
        exact_conflicts.append((key, lst))
exact_conflicts.sort(key=lambda x: (-len(set(y[1] for y in x[1])), x[1][0][0]))

# ---------- 顺序遮蔽 ----------
exact_first = {}
suffix_first = {}
for i, r in enumerate(rules):
    if r["type"] == "DOMAIN":
        exact_first.setdefault(r["value"].lower(), (i, r["target"], r["type"], r["value"]))
    elif r["type"] == "DOMAIN-SUFFIX":
        suffix_first.setdefault(r["value"].lower().lstrip("+.*"), (i, r["target"], r["type"], r["value"]))

# 关键词按位置排序，供逐条检查
keyword_list = [(i, r["value"].lower(), r["target"]) for i, r in kw_rules]
ruleset_rules = [(i, r["target"], r["value"]) for i, r in enumerate(rules) if r["type"] == "RULE-SET"]

misrouted = []      # 生效目标 != 声明目标
redundant_same = 0  # 被同目标更早规则覆盖（冗余但无害）
effective_self = 0
for i, r in domain_rules:
    host = r["value"].lower().lstrip("+.*")
    cands = [(i, r["target"], r["type"], r["value"])]
    if host in exact_first:
        cands.append(exact_first[host])
    labels = host.split(".")
    for k in range(len(labels)):
        suf = ".".join(labels[k:])
        if suf in suffix_first:
            cands.append(suffix_first[suf])
    for ki, kw, kt in keyword_list:
        if ki < i and kw in host:
            cands.append((ki, kt, "DOMAIN-KEYWORD", kw))
    for ri, rt, rv in ruleset_rules:
        if ri < i and rv.lower() == "cn" and in_cn(host):
            cands.append((ri, rt, "RULE-SET", rv))
    win = min(cands, key=lambda x: x[0])
    if win[0] == i:
        effective_self += 1
    elif win[1] == r["target"]:
        redundant_same += 1
    else:
        intended_cn = (win[2] == "RULE-SET" and win[3].lower() == "cn" and win[1] == DIRECT_GROUP)
        misrouted.append({
            "pos": i, "rule": f'{r["type"]},{r["value"]}', "declared": r["target"], "section": sec_of(i),
            "winner_pos": win[0], "winner": f'{win[2]},{win[3]}', "winner_target": win[1], "winner_section": sec_of(win[0]),
            "intended_cn": intended_cn,
        })

# 「一边直连/拦截、另一边代理」= 严重改道
SEVERE_GROUPS = (DIRECT_GROUP, AD_GROUP)
sev = lambda x: (x["declared"] in SEVERE_GROUPS) != (x["winner_target"] in SEVERE_GROUPS)
misrouted_cn = [x for x in misrouted if x["intended_cn"]]
misrouted_severe = [x for x in misrouted if sev(x) and not x["intended_cn"]]
misrouted_group = [x for x in misrouted if not sev(x) and not x["intended_cn"]]
misrouted.sort(key=lambda x: x["pos"])

# MATCH 之后是否还有规则
match_pos = next((i for i, r in enumerate(rules) if r["type"] == "MATCH"), None)
after_match = len(rules) - match_pos - 1 if match_pos is not None else 0

# ---------- 组状态 ----------
proxies = json.load(open(PROXIES, encoding="utf-8"))["proxies"] if os.path.exists(PROXIES) else {}
def egress(group):
    chain = []
    cur = group
    for _ in range(12):
        node = proxies.get(cur, {})
        nxt = node.get("now")
        if not nxt:
            break
        chain.append(nxt)
        cur = nxt
        if proxies.get(cur, {}).get("type") in ("Direct", "Reject"):
            break
    return cur, chain

group_rows = []
for g in d.get("proxy-groups", []):
    name = g["name"]
    node = proxies.get(name, {})
    now = node.get("now", "")
    eg, chain = egress(name)
    members = len(node.get("all", [])) or len(g.get("proxies") or [])
    group_rows.append({"name": name, "type": g.get("type"), "now": now, "egress": eg, "chain": chain, "members": members})

# ---------- 域名匹配 ----------
def match_host(host):
    h = host.lower().rstrip(".")
    for i, r in enumerate(rules):
        t = r["type"]
        if t == "MATCH":
            return i, r
        if t == "DOMAIN":
            if h == r["value"].lower():
                return i, r
        elif t == "DOMAIN-SUFFIX":
            v = r["value"].lower().lstrip("+.*")
            if h == v or h.endswith("." + v):
                return i, r
        elif t == "DOMAIN-KEYWORD":
            if r["value"].lower() in h:
                return i, r
        elif t == "RULE-SET":
            if r["value"].lower() == "cn" and in_cn(h):
                return i, r
    return None, None

# 代表性域名：expected 取值 ad/direct/proxy/ai/fcm/telegram/netflix/disney/ms/apple/cn/google_svc/google_direct
TESTS = [
    # Google 功能
    ("www.google.com", "google_svc"), ("accounts.google.com", "google_svc"),
    ("clients2.google.com", "google_svc"), ("clients4.google.com", "google_svc"),
    ("update.googleapis.com", "google_svc"), ("safebrowsing.googleapis.com", "google_svc"),
    ("play.googleapis.com", "google_svc"), ("android.clients.google.com", "google_svc"),
    ("www.googleapis.com", "google_svc"), ("fcm.googleapis.com", "google_svc"),
    ("firebaseinstallations.googleapis.com", "google_svc"), ("mtalk.google.com", "fcm"),
    ("dl.google.com", "google_direct"), ("redirector.gvt1.com", "google_svc"),
    ("lh3.googleusercontent.com", "google_svc"), ("www.gstatic.com", "google_svc"),
    ("ssl.gstatic.com", "google_svc"), ("youtube.com", "media"), ("youtubei.googleapis.com", "media"),
    ("googletagmanager.com", "google_direct"), ("safebrowsing-cache.google.com", "google_direct"),
    # Google AI
    ("gemini.google.com", "ai"), ("aistudio.google.com", "ai"), ("notebooklm.google.com", "ai"),
    ("ai.google.dev", "ai"), ("generativelanguage.googleapis.com", "ai"),
    ("cloudaicompanion.googleapis.com", "ai"), ("antigravity.google", "ai"),
    # 广告
    ("doubleclick.net", "ad"), ("googlesyndication.com", "ad"), ("googleadservices.com", "ad"),
    ("pagead2.googlesyndication.com", "ad"), ("analytics.google.com", "ad"),
    ("csi.gstatic.com", "ad"), ("adservice.google.com", "ad"), ("ads.google.com", "ad"),
    ("connect.facebook.net", "ad"), ("google-analytics.com", "ad"),
    # AI 服务
    ("chatgpt.com", "ai"), ("chat.com", "ai"), ("openai.com", "ai"), ("oaistatic.com", "ai"),
    ("oaiusercontent.com", "ai"), ("sora.com", "ai"), ("claude.ai", "ai"),
    ("anthropic.com", "ai"), ("api.anthropic.com", "ai"), ("console.anthropic.com", "ai"),
    ("opencode.ai", "ai"), ("copilot.microsoft.com", "ai"), ("githubcopilot.com", "ai"),
    ("perplexity.ai", "ai"), ("poe.com", "ai"), ("huggingface.co", "ai"), ("hf.co", "ai"),
    ("midjourney.com", "ai"), ("replicate.com", "ai"), ("groq.com", "ai"), ("x.ai", "ai"),
    ("grok.com", "ai"), ("together.ai", "ai"),
    # 开发/基础设施
    ("github.com", "proxy"), ("raw.githubusercontent.com", "proxy"), ("objects.githubusercontent.com", "proxy"),
    ("githubusercontent.com", "proxy"), ("githubassets.com", "proxy"), ("gitlab.com", "proxy"),
    ("registry.npmjs.org", "proxy"), ("pypi.org", "proxy"), ("files.pythonhosted.org", "proxy"),
    ("nodejs.org", "proxy"), ("docker.io", "proxy"), ("ghcr.io", "proxy"), ("gcr.io", "proxy"),
    ("stackoverflow.com", "proxy"), ("cloudflare.com", "proxy"), ("jsdelivr.net", "proxy"),
    # 媒体
    ("netflix.com", "netflix"), ("nflxvideo.net", "netflix"), ("nflximg.net", "netflix"),
    ("disneyplus.com", "disney"), ("dssott.com", "disney"), ("bamgrid.com", "disney"),
    ("spotify.com", "media"), ("scdn.co", "media"), ("twitch.tv", "media"), ("ttvnw.net", "media"),
    ("primevideo.com", "media"), ("music.apple.com", "apple"), ("tv.apple.com", "apple"),
    # 微软/苹果
    ("microsoft.com", "ms"), ("login.live.com", "ms"), ("office.com", "ms"),
    ("office365.com", "ms"), ("onedrive.live.com", "proxy"), ("windowsupdate.com", "ms"),
    ("xbox.com", "ms"), ("www.bing.com", "ms"), ("sydney.bing.com", "ai"),
    ("sharepointonline.com", "proxy"),
    ("apple.com", "apple"), ("icloud.com", "apple"),
    ("mzstatic.com", "apple"), ("swcdn.apple.com", "apple"), ("ocsp.apple.com", "apple"),
    # 电报
    ("telegram.org", "telegram"), ("t.me", "telegram"), ("telegra.ph", "telegram"),
    ("tdesktop.com", "telegram"),
    # 国内
    ("baidu.com", "cn"), ("taobao.com", "cn"), ("jd.com", "cn"), ("weibo.com", "cn"),
    ("zhihu.com", "cn"), ("bilibili.com", "cn"), ("hdslb.com", "cn"), ("alipay.com", "cn"),
    ("wechat.com", "cn"), ("qq.com", "cn"), ("163.com", "cn"), ("aliyun.com", "cn"),
    ("tencent.com", "cn"), ("126.net", "cn"),
    # CN 例外 / 宽泛代理冲突
    ("tmall.hk", "cn"), ("jd.hk", "cn"), ("cm.steampowered.com", "direct"),
    # 其他
    ("steamcommunity.com", "proxy"), ("steamstatic.com", "proxy"),
    ("epicgames.com", "direct"),
    ("discord.com", "proxy"), ("discordapp.com", "proxy"), ("whatsapp.com", "proxy"),
    ("signal.org", "proxy"), ("zoom.us", "proxy"), ("slack.com", "proxy"), ("notion.so", "proxy"),
    ("sentry.io", "proxy"), ("disney.my.sentry.io", "disney"), ("googleapis.com", "proxy"),
]

test_rows = []
for host, expected in TESTS:
    pos, r = match_host(host)
    target = r["target"] if r else "?"
    eg, chain = egress(target) if target in proxies else ("?", [])
    if expected == "ad":
        ok = target == AD_GROUP
    elif expected in ("direct", "google_direct"):
        ok = eg == "DIRECT"
    elif expected == "ai":
        ok = target in AI_GROUPS
    elif expected == "fcm":
        ok = target == FCM_GROUP
    elif expected == "telegram":
        ok = target == TELEGRAM_GROUP
    elif expected == "netflix":
        ok = target == NETFLIX_GROUP
    elif expected == "disney":
        ok = target == DISNEY_GROUP
    elif expected == "ms":
        ok = target == MS_GROUP
    elif expected == "apple":
        ok = target == APPLE_GROUP
    elif expected == "cn":
        ok = eg == "DIRECT"
    else:  # proxy / google_svc / media
        ok = eg not in ("DIRECT", "REJECT") and target != AD_GROUP
    test_rows.append({"host": host, "expected": expected, "pos": pos, "rule": f'{r["type"]},{r["value"]}' if r else "?", "target": target, "egress": eg, "section": sec_of(pos) if pos is not None else "?", "ok": ok})

# ---------- 广告审计 ----------
ad_rules = [(i, r) for i, r in enumerate(rules) if r["target"] == AD_GROUP]
ad_kw = [(i, r) for i, r in ad_rules if r["type"] == "DOMAIN-KEYWORD"]
functional = [h for h, e in TESTS if e not in ("ad",)]
def rule_matches(r, host):
    h = host.lower()
    if r["type"] == "DOMAIN": return h == r["value"].lower()
    if r["type"] == "DOMAIN-SUFFIX":
        v = r["value"].lower().lstrip("+.*"); return h == v or h.endswith("." + v)
    if r["type"] == "DOMAIN-KEYWORD": return r["value"].lower() in h
    return False
ad_fp = []
for i, r in ad_rules:
    hits = [h for h in functional if rule_matches(r, h)]
    if hits:
        ad_fp.append({"pos": i, "rule": f'{r["type"]},{r["value"]}', "hits": hits[:6], "section": sec_of(i)})

# ---------- Google 矩阵 ----------
google_rules = []
for i, r in enumerate(rules):
    v = r["value"].lower()
    if any(k in v for k in ("google", "gstatic", "gvt1", "ggpht", "googleapis", "youtube", "android")):
        google_rules.append({"pos": i, "rule": f'{r["type"]},{r["value"]}', "target": r["target"], "section": sec_of(i)})
google_by_target = collections.Counter((x["target"], x["section"]) for x in google_rules)

# Phase 2 影响面：RULE-SET,cn 会覆盖哪些后续非 DIRECT 域名规则
cn_rules = [i for i, r in enumerate(rules) if r["type"] == "RULE-SET" and r["value"].lower() == "cn"]
cn_impact = []
if cn_rules and cn_suffix:
    cn_pos = cn_rules[0]
    for i, r in domain_rules:
        if i > cn_pos and r["target"] != DIRECT_GROUP:
            host = r["value"].lower().lstrip("+.*")
            if in_cn(host):
                cn_impact.append({"pos": i, "rule": f'{r["type"]},{r["value"]}', "declared": r["target"],
                                  "section": sec_of(i), "cn_rule_pos": cn_pos})
cn_impact_by = collections.Counter((x["declared"], x["section"]) for x in cn_impact)

# ---------- 输出 ----------
def md_table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join(["---"] * len(headers)) + "|"]
    for row in rows:
        out.append("| " + " | ".join(str(x).replace("|", "\\|") for x in row) + " |")
    return "\n".join(out)

L = []
L.append("# mihomo 规则审计报告\n")
L.append(f"数据：`{CONFIG}`（{len(rules)} 条规则），组状态 `{PROXIES}`，上游列表 `{LISTDIR}/`\n")
L.append(f"分组口径：直连 `{DIRECT_GROUP}`；广告 `{AD_GROUP}`；AI `{', '.join(AI_GROUPS)}`；"
         f"FCM `{FCM_GROUP}`；电报 `{TELEGRAM_GROUP}`；Netflix `{NETFLIX_GROUP}`；"
         f"Disney `{DISNEY_GROUP}`；微软 `{MS_GROUP}`；苹果 `{APPLE_GROUP}`\n")
L.append("## 1. 规则结构\n")
L.append("### 1.1 按类型\n")
L.append(md_table(["类型", "条数"], type_counts.most_common()))
L.append("\n### 1.2 按目标组\n")
L.append(md_table(["目标组", "条数"], target_counts.most_common()))
L.append("\n### 1.3 按来源列表（模板顺序）\n")
sec_rows = []
for s in sections:
    ts = collections.Counter(rules[i]["target"] for i in range(s["start"], s["end"]) if i < len(rules))
    sec_rows.append([s["name"], f'{s["start"]}..{s["end"]-1}', s["end"] - s["start"], s["list_count"], ", ".join(f"{k}:{v}" for k, v in ts.most_common(3))])
L.append(md_table(["来源", "索引", "生成条数", "上游条数", "目标分布"], sec_rows))

L.append("\n## 2. 策略组状态\n")
L.append(md_table(["组", "类型", "当前选择", "实际出口", "链", "候选数"],
    [[g["name"], g["type"], g["now"], g["egress"], " → ".join(g["chain"]), g["members"]] for g in group_rows]))

L.append("\n## 3. 顺序与遮蔽（核心）\n")
L.append(f"- 域名规则：{len(domain_rules)} 条；关键词规则：{len(kw_rules)} 条")
L.append(f"- 自身即为最早匹配（真正生效）：{effective_self} 条")
L.append(f"- 被同目标更早规则覆盖（冗余无害）：{redundant_same} 条")
L.append(f"- **生效目标 != 声明目标（顺序导致的实际改道）：{len(misrouted)} 条**")
L.append(f"  - 严重（一边是 DIRECT/REJECT，另一边是代理）：{len(misrouted_severe)} 条")
L.append(f"  - 组级差异（两边都是代理，但组不同）：{len(misrouted_group)} 条")
L.append(f"  - 有意的 CN 直连覆盖（RULE-SET,cn）：{len(misrouted_cn)} 条")
L.append(f"- MATCH 之后的规则：{after_match} 条（应为 0）")
L.append(f"- 精确重复且目标不同：{len(exact_conflicts)} 组\n")

L.append("### 3.1 严重改道（前 40）\n")
rows = []
for x in misrouted_severe[:40]:
    rows.append([x["pos"], x["rule"], x["section"], x["declared"], x["winner_pos"], x["winner"], x["winner_target"]])
L.append(md_table(["#", "被遮蔽规则", "来源", "声明目标", "生效#", "生效规则", "生效目标"], rows))

L.append("\n### 3.2 组级改道 Top 30\n")
grp = collections.Counter((x["declared"], x["winner_target"]) for x in misrouted_group)
L.append(md_table(["声明目标", "实际目标", "条数"], [[a, b, c] for (a, b), c in grp.most_common(30)]))

L.append("\n### 3.3 精确冲突（同一 pattern 多目标，前 30）\n")
rows = []
for key, lst in exact_conflicts[:30]:
    rows.append([f"{key[0]},{key[1]}", ", ".join(f"#{p}→{t}" for p, t, s in lst[:6])])
L.append(md_table(["pattern", "出现位置→目标"], rows))

L.append("\n## 4. 广告拦截审计\n")
L.append(f"- 广告规则总数：{len(ad_rules)}；其中关键词规则 {len(ad_kw)} 条")
L.append("- 关键词规则：")
for i, r in ad_kw:
    L.append(f"  - `{r['value']}` (#{i}, {sec_of(i)})")
L.append("\n- 可能误伤功能域名的广告规则：")
if ad_fp:
    L.append(md_table(["#", "规则", "来源", "会命中的功能域名"], [[x["pos"], x["rule"], x["section"], ", ".join(x["hits"])] for x in ad_fp[:40]]))
else:
    L.append("  无（针对测试集）。")

L.append("\n## 5. Google 家族分布\n")
L.append(md_table(["目标组", "来源", "条数"], [[a, b, c] for (a, b), c in google_by_target.most_common(30)]))

L.append("\n## 5.1 Phase 2 影响面（RULE-SET,cn 模拟）\n")
if cn_rules and cn_suffix:
    L.append(f"- cn 规则位置：#{cn_rules[0]}；geosite:cn 后缀模式：{len(cn_suffix)}")
    L.append(f"- 会被改判为 DIRECT 的后续非 DIRECT 域名规则：{len(cn_impact)} 条")
    L.append(md_table(["声明目标", "来源", "条数"], [[a, b, c] for (a, b), c in cn_impact_by.most_common(30)]))
    if cn_impact:
        L.append("\n前 40 条：")
        L.append(md_table(["#", "规则", "声明目标", "来源"], [[x["pos"], x["rule"], x["declared"], x["section"]] for x in cn_impact[:40]]))
else:
    L.append("- 未检测到 RULE-SET,cn，或未提供 geosite:cn 文本列表（第 5 个参数）。")

L.append("\n## 6. 代表性域名归类\n")
rows = []
for t in test_rows:
    flag = "" if t["ok"] else "⚠"
    rows.append([flag, t["host"], t["expected"], t["pos"], t["rule"], t["target"], t["egress"], t["section"]])
L.append(md_table(["", "域名", "期望", "#", "命中规则", "目标组", "实际出口", "来源"], rows))

L.append("\n## 7. 结论\n")
L.append(f"- 测试集 {len(test_rows)} 个域名，符合预期 {sum(1 for t in test_rows if t['ok'])} 个，异常 {sum(1 for t in test_rows if not t['ok'])} 个。")
L.append(f"- 顺序改道：严重 {len(misrouted_severe)} 条，组级差异 {len(misrouted_group)} 条。")
L.append("- 详见上方表格；异常项需要人工确认是“有意覆盖”还是“模板顺序副作用”。")

open(REPORT, "w", encoding="utf-8").write("\n".join(L))
json.dump({
    "summary": {"total": len(rules), "types": type_counts, "targets": target_counts,
                "effective_self": effective_self, "redundant_same": redundant_same,
                "misrouted": len(misrouted), "misrouted_severe": len(misrouted_severe),
                "misrouted_group": len(misrouted_group), "misrouted_cn": len(misrouted_cn),
                "after_match": after_match, "cn_impact": len(cn_impact),
                "exact_conflicts": len(exact_conflicts), "tests_fail": [t for t in test_rows if not t["ok"]]},
    "sections": sections, "groups": group_rows,
    "misrouted_severe": misrouted_severe[:200], "misrouted_group_top": grp.most_common(50),
    "exact_conflicts": [[key, lst] for key, lst in exact_conflicts[:200]],
    "ad_false_positive": ad_fp, "tests": test_rows,
    "cn_impact": cn_impact[:300],
}, open(FINDINGS, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(f"wrote {REPORT} and {FINDINGS}")
print(f"rules={len(rules)} effective={effective_self} redundant={redundant_same} misrouted={len(misrouted)} (severe={len(misrouted_severe)}, group={len(misrouted_group)}) tests_fail={sum(1 for t in test_rows if not t['ok'])}/{len(test_rows)}")
