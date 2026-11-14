# 工具清单

> **一句话**：三个域每个脚本干什么、会不会改设备状态，以及完整的目录结构 —— 根 README 只留用户门面的速览。
> 三个域各解决什么问题、适合谁、边界在哪，见 [ARCHITECTURE.md](ARCHITECTURE.md) §1。

## 目录结构

```
OpenwrtOpsToolkit/
├─ openwrt/
│  ├─ guardian.sh            网络守护：出口组复原 / nft 表补载 / 探活；收尾写 guardian.state（--status 只读体检）
│  ├─ bulk-guard.sh          大流量组守卫：按真实吞吐决定走公共池还是机场
│  ├─ traffic-stats.sh       流量归因：采样 /connections，按「命中的策略组 + 域名」记上下行字节（--report 按天 / --summary 跨天分账）
│  ├─ recover-now.sh         离线恢复：DNS 解析全失败、代理离线
│  ├─ rc.local               开机自启模板（/tmp 运行时目录、nft 表、/var 兜底）
│  ├─ post-sc-update.sh      ShellCrash 官方脚本更新后恢复本地补丁
│  ├─ setup-zram.sh          低内存设备启用 zram 压缩 swap（装包 + 写 uci + 调 `vm.swappiness`，幂等，换固件后重跑）
│  ├─ ops-status.sh          只读健康快照 / 自检：把各脚本的状态拼成固定 schema 的 JSON（`openwrt-ops-status/1`），并进跨仓三状态口，给控制台与运维工具消费
│  └─ conf/device.conf.example  设备配置样例（复制成 device.conf 再改）
├─ mihomo/
│  ├─ mihomo_api.py          控制 API 客户端库（IPv6 + 重试 + chunked 解码）
│  ├─ rule_audit.py          规则审计器：声明目标 vs 实际生效目标
│  ├─ scan_rules.py          流式扫 /rules
│  ├─ mihomo_log.py          实时日志（临时提 debug 级再恢复）
│  ├─ capture_live.py        增量抓日志到文件
│  └─ latency_probe.py       策略组与节点握手延迟
├─ cdn/
│  ├─ qq_cdn_probe.py        CDN 连通性：分 DNS / TCP / TLS / HTTP 段计时
│  ├─ qq_dns_path.py         判定域名是否落在 cn 规则集内
│  ├─ qq_domain_classify.py  逐域名判定：直连还是漏网
│  ├─ qq_rule_probe.py       边抓日志边看命中了哪条规则
│  └─ quic_probe.py          QUIC 能力探测
├─ tools/check-docs.py       文档自检（链接 / 锚点 / 引言块 / 孤儿）
├─ tools/check-secrets.py    公开仓敏感信息扫描（凭据 / 本机路径 / 真实邮箱）
├─ tools/check-shell-shared-blocks.py  跨脚本共享块一致性门禁（`# >>> shared:<id> >>>` 标记块逐字比对）
├─ tools/github-setup.py     批量配置 GitHub 仓库：可见性 / 描述 / 话题
├─ tools/make_social_preview.py  从 assets/icon.svg 渲染 logo 与社交预览图
├─ docs/                     文档（README.md 是唯一索引）
└─ assets/                   logo
```

## 会改设备状态吗

| 文件 | 作用 | 会改设备状态吗 |
|---|---|---|
| `openwrt/guardian.sh` | 每 5 分钟巡检一次，必要时做最小化修复；每轮收尾原子写 `$RUNTIME_DIR/ops-guardian.state`（tmpfs，键名对齐 `AX3000TOpenwrt` 的 `guardian.state` 但文件名分开，避免两版同装互相覆盖），`--status` 出只读体检（不取锁、不写日志与状态文件） | ⚠️ 会（但只做自愈动作） |
| `openwrt/bulk-guard.sh` | 每 3 分钟判定一次大流量组走公共池还是机场；钉点/候选用 `proof.ovh.net` 做二次校验（gstatic 通不代表能跑大文件），慢时先在公共池内按吞吐缓存改试（每会话最多 2 个），空闲时每 2 小时实测一次吞吐（阈值 `BULK_MIN_BPS`，默认 800 KB/s，可按设备下调）；**空池单独判定**（池子只剩内置直连时立刻切机场，在机场时找不到双通节点就不切回） | ⚠️ 会（切策略组，并把公共池钉到具体节点） |
| `openwrt/traffic-stats.sh` | 每分钟采样 mihomo `/connections`，按「命中的策略组 + 域名」累计上下行字节（nlbwmon 只按 LAN 主机记账，答不了「机场流量被谁吃了」）；差值先攒 `/tmp` 缓冲，默认每 10 分钟（`STATS_FLUSH_MIN`，0=逐分钟）聚合落盘当日 tsv，只留 31 天；`--report` 按天打印按组 / 按域名累计；`--summary` 跨天合成一张账 —— 按「机场出口 / 直连 / 兜底」三分类分账 + 按组合计 top15 + 域名 top20（分账口径用 `STATS_AIRPORT_GROUPS` / `STATS_DIRECT_GROUPS` 覆盖，见 `openwrt/conf/device.conf.example`） | ⚠️ 会（写 `$CRASHDIR/stats/` 当日统计与 `$RUNTIME_DIR` 采样状态；不切组、不改配置） |
| `openwrt/recover-now.sh` | 手动触发的成套恢复 | ⚠️ 会（重生成配置、重载 fw4） |
| `openwrt/rc.local` | 开机自启模板 | ⚠️ 会（装到 `/etc/rc.local`） |
| `openwrt/post-sc-update.sh` | ShellCrash 更新后恢复本地补丁；验收段按 `CrashCore.upx` → `CrashCore.raw` → 运行态软链动态探测内核跑 `-t`（见 [PITFALLS.md](PITFALLS.md) P46） | ⚠️ 会（覆盖 starts/ 下三个文件） |
| `openwrt/setup-zram.sh` | 低内存设备启用压缩 swap：装 `kmod-zram` / `zram-swap`、把大小与压缩算法写进 uci、调 `vm.swappiness`，用 CPU 换内存避免瞬时峰值被 OOM killer 杀核心；`--status` 只报告不改，换固件后重跑一次；适配参考见 [PITFALLS.md](PITFALLS.md) P47 | ⚠️ 会（apk 装包、`uci set` + `uci commit system`、写 `/etc/sysctl.d/99-zram.conf`；装完立刻有 swap，**大小与算法重启后生效**） |
| `openwrt/ops-status.sh` | 只读健康快照 / 自检：读各脚本的日志、锁、状态文件与 `/proc`、`df`，拼成 schema 固定的 JSON（`openwrt-ops-status/1`）；`cross_repo` 段并进三个状态口（守护状态按 `ops-guardian.state` → `guardian.state` 探测 / `dest-guard.state` / `health.json`，带 `present` 与 `age_s`）；`--self-check` 出人读自检（配置解析 / 依赖 / 权限 / 日志水位 / 状态口新鲜度）。**不取实例锁、不写任何设备状态** | ❌ 只读 |
| `mihomo/*.py` | 诊断 | ❌ 只读 |
| `cdn/*.py` | 诊断 | ❌ 只读 |

「会改什么、怎么改」的机制正本见 [ARCHITECTURE.md](ARCHITECTURE.md)；坑位见 [PITFALLS.md](PITFALLS.md)。
