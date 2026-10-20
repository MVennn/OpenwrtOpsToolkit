---
name: redir-mode-udp-quic-leak
description: OpenWrt 透明代理(Redir)模式下 UDP 全部绕过代理，浏览器 QUIC 直出带国内 IP，导致网页外壳能开但 UI 加载不全
metadata:
  node_type: memory
  type: project
  originSessionId: session_5fe631d5f57189c091c6560e6cbdf7ab
---

**现象（2026-10-20 某台 OpenWrt + ShellCrash Redir）**：Chrome 打开 `gemini.google.com` 只剩输入框，
推荐区/侧栏不出现，**无痕模式同样失败**（→ 排除扩展与 Cookie）。同一时刻 ZCode 内置浏览器正常。

**根因**：Redir 模式只转 TCP，**UDP 根本不进 mihomo**。Chrome 优先用 HTTP/3(QUIC, UDP 443)，
QUIC 直出 WAN → 带中国出口 IP → Google 判为 CN → 页面资源被降级/拒绝。
Electron 默认不启用 QUIC，所以「你坏它好」。原有 QUIC 拦截只覆盖假 IP 段(198.18/15)与
国内边缘段(203.208.32.0/19)，**真实 Google IP 的 QUIC 完全漏网**。

**修复**：全局阻断 UDP 443/8443（`/etc/quicguard.nft`，独立 `inet quicguard` 表，priority -150），
代价是国内应用的 QUIC 也回落 TCP，换来同一会话单一出口 IP。加完后 Chrome 的 QUIC 被拦 25 次并回落 TCP，
`gemini.google.com` 下载 1.07MB、`gemini.gstatic.com` 1.56MB，UI 拉全。

**2026-10-20 晚修正：全局阻断必须给国内目标开豁免。**
全局 `udp dport {443,8443} reject` 会连**国内应用的 QUIC 一起掐死**：
- 路由器 `dns_mod=mix` → `clash_modify.sh` 给 fake-ip-filter 追加 `rule-set:cn`
  → cn 域名解析成**真实 CDN IP**（不是 fake-ip），QUIC 直接打到真实 CDN。
- **Linux 不把 ICMP 端口不可达交给应用** → App 不知 QUIC 失败，只能等握手超时才回落 TCP
  → QQ 聊天页一页几十张缩略图，**每张都先空几秒**（2026-10-20 用户报"手机 QQ 缩略图出不来"）。
- 正确做法：quicguard 链首两条放行国内目标
  `ip daddr @inet shellcrash cn_ip return` / `ip6 daddr @inet shellcrash cn_ip6 return`。
  集合由 ShellCrash 维护在 `inet shellcrash` 表，**已剔除 Google 中国边缘段** 203.208.32.0/19 与
  2401:3800::/32，所以 Google 仍拿不到 QUIC、不会被判 CN。境外目标照旧拦。
- 另一个坑：`fw_nftables.sh` 里同款 reject 落在 **nat 链**（nft 不允许 nat 链用 reject）→ **命令静默失败**，
  真正生效的只有 quicguard 表那几条。
- 部署坑：`nft -f` 的 `add table`/`add chain` 语义**不会替换已有表**，改完文件必须
  `nft destroy table inet quicguard` 再 `nft -f`；且 `guardian.sh` 第 4 节只在表**缺失**时重载，
  **表内容写错永远不会被纠正**。

**判别方法**：浏览器类问题先看传输层——把 UDP 443 全局拦掉再复测；或在 mihomo 连接里看
`destinationIP` 与下载字节是否停在半截。

**配套**：`ai-api-check.sh` 第 16 节校验该规则。校验 live nft 表时注意输出格式是
`counter packets N bytes M reject`，不是 `counter reject`；用 `grep -q "udp dport { 443, 8443 } counter packets"` 匹配，
否则会误判为「规则缺失」并每 5 分钟重载表、把计数器清零。

相关：[[shellcrash-ai-routing-fix]]、[[chrome-lna-fakeip-conflict]]、[[ax3000t-router-environment]]
