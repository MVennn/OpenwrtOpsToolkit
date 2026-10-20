---
name: shellcrash-rule-reorg
description: ShellCrash 规则重组：rules.yaml 三层结构、分类修正层顺序约束、rules-mid CN 中间层，含验证结果与已知坑
metadata:
  node_type: memory
  type: project
  originSessionId: sess_8a5d2dac-14e8-4ce6-ac70-a28d352735db
---

2026-10-19 完成。详细文档 规则审计报告（本仓 `mihomo/rule_audit.py` 的输出），
审计数据 规则审计的输入快照（含 139 域名回归报告和 findings.json）。

## rules.yaml 的三层结构

`ai-rules-update.sh` 生成 `yamls/rules.yaml`，整文件插到模板规则之前：

1. **硬覆盖**：opencode.ai → <AI接口组>；Google Play/更新/FCM → <通用代理组>。
2. **geosite AI 规则**：MetaCubeX category-ai-chat-!cn 约 192 条 → <AI策略组>。
3. **分类修正层**（文件末尾，仍在模板之前）：修正 ai.list/ProxyLite/ChinaDomain 的过宽与顺序问题。

修正层的顺序是硬约束，任何重排都会破坏分类：

- `bat.bing.com` < `sydney.bing.com`/`edgeservices.bing.com` < `bing.com → 微软服务`
- `o33249.ingest.sentry.io` < `disney.my.sentry.io` < `sentry.io → <通用代理组>`
- `youtubei.googleapis.com` < 宽泛 `googleapis.com → <通用代理组>`

覆盖内容：Bing 搜索直连、Copilot 走 AI、OneDrive/SharePoint 代理、Sentry/Intercom/
Auth0/Statsig 等共享 SaaS 不再被钉在 AI 组、Disney 的 Sentry 保留 DisneyP、
tmall.hk/jd.hk/cm.steampowered.com 直连。

**Epic 不做代理覆盖**：直连和代理都返回 403（Cloudflare challenge），与分流无关；
`cm.steampowered.com` 当前是 NXDOMAIN，规则仅作未来兼容。

## Phase 2：CN 直连中间层

- `/etc/ShellCrash/rules-mid.sh`：在生成的 config 中插入
  ` - RULE-SET,cn,🎯 全球直连`，位置是最后一条 `📲 电报消息` 规则之后、
  `DOMAIN-SUFFIX,edgedatg.com,🌍 国外媒体` 之前。
- 钩子在 `starts/clash_modify.sh` 的 `merger_yaml` 之后、`reorder-groups.sh` 之前。
- `ai-api-check.sh` 第 8 节检查：脚本可执行、钩子在、插入位置正确。
- `/etc/ShellCrash/rules-mid.sh` 已在 sysupgrade 保留清单。
- **运行中的 `cn.mrs` 可能滞后于文本 geosite:cn**：例如 `joox.com` 在文本列表里、
  但 mrs 没收录时仍走国外媒体。审计工具用文本列表模拟，不能完全代表运行态。

## 验证基线

- `rule_audit.py`：13,046 条规则，**139 个代表域名 0 异常**；13 条 severe 均为有意覆盖
  （9 条 FCM、2 条 flashtalking 广告、app-measurement 直连、2mdn 广告）。
- `CrashCore.raw -t` 通过；`RULE-SET,cn` 位于 #3158。
- 实况：OneDrive 带浏览器 UA 302、Bing 302 直连、sydney AI、Play/AI 可达、
  `ip138.com` DIRECT、`jd.hk` DIRECT、`www.google.com` 香港代理。
- `ai-api-check.sh` 1–8 节全部通过（三协议 200）。

## 运维观察（2026-10-19 菜单重启）

- ShellCrash 菜单选 1 / 重启会重新生成 config，随后 `rules-mid` 钩子再次插入；
  每次看到 `rules-mid: inserted ... at line 3158` 都是预期输出，不是重复部署。
- **`pgrep -f CrashCore` 会把它自己的 `ash -c ...` 命令也匹配进来**，看起来像两个实例；
  实际确认要用 `netstat -lntp | grep -E ':7892|:9999|:1053'` + `/tmp/ShellCrash/shellcrash.pid`。
  本次实际只有单个 PID（14515）监听 7892/9999/1053。
- 重启后快速确认：`RULE-SET,cn` 计数=1、分类修正规则仍在（bat.bing.com/Disney Sentry/OneDrive/Steam）、
  `quicguard` counter 继续增长、`fake-ip-filter` 的 googleusercontent 排除仍在。

## 策略组成员顺序（2026-10-19 追加）

- `reorder-groups.sh` 现在跑两遍：第一遍排 `proxy-groups` 顶层顺序；第二遍排
  `<通用代理组>` 的**成员**顺序。
- 成员目标顺序：`<自动选择组>` → `<AI接口组>` → 各地区组 →
  `🚀 手动切换` → `DIRECT`。自定义组会被 `clash_modify.sh` 倒序前置插入，
  所以必须靠第二遍重排，否则 `<自动选择组>` 会被挤到第 6 位。
- **awk + emoji 的坑**：Git Bash/BusyBox awk 在 C locale 下，含 emoji 的**正则**
  （如 `/^  - name: <通用代理组>/`）可能匹配不到；用**字符串相等**
  （`$0 == "  - name: <通用代理组>"`）或 `index()` 才可靠。
- 健康检查脚本会检查 `<通用代理组>` 首项是否为 `<自动选择组>`。

相关：[[shellcrash-ai-routing-fix]]、[[chrome-lna-fakeip-conflict]]、[[ax3000t-router-environment]]
