# 工具清单

> **一句话**：三个域每个脚本干什么、会不会改设备状态，以及完整的目录结构 —— 根 README 只留用户门面的速览。
> 三个域各解决什么问题、适合谁、边界在哪，见 [ARCHITECTURE.md](ARCHITECTURE.md) §1。

## 目录结构

```
OpenwrtOpsToolkit/
├─ openwrt/
│  ├─ guardian.sh            网络守护：出口组复原 / nft 表补载 / 探活
│  ├─ bulk-guard.sh          大流量组守卫：按真实吞吐决定走公共池还是机场
│  ├─ recover-now.sh         离线恢复：DNS 解析全失败、代理离线
│  ├─ rc.local               开机自启模板（/tmp 运行时目录、nft 表、/var 兜底）
│  ├─ post-sc-update.sh      ShellCrash 官方脚本更新后恢复本地补丁
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
├─ tools/github-setup.py     批量配置 GitHub 仓库：可见性 / 描述 / 话题
├─ tools/make_social_preview.py  从 assets/icon.svg 渲染 logo 与社交预览图
├─ docs/                     文档（README.md 是唯一索引）
└─ assets/                   logo
```

## 会改设备状态吗

| 文件 | 作用 | 会改设备状态吗 |
|---|---|---|
| `openwrt/guardian.sh` | 每 5 分钟巡检一次，必要时做最小化修复 | ⚠️ 会（但只做自愈动作） |
| `openwrt/bulk-guard.sh` | 每 3 分钟判定一次大流量组走公共池还是机场；钉点/候选用 `proof.ovh.net` 做二次校验（gstatic 通不代表能跑大文件），慢时先在公共池内按吞吐缓存改试（每会话最多 2 个），空闲时每 2 小时实测一次吞吐 | ⚠️ 会（切策略组，并把公共池钉到具体节点） |
| `openwrt/recover-now.sh` | 手动触发的成套恢复 | ⚠️ 会（重生成配置、重载 fw4） |
| `openwrt/rc.local` | 开机自启模板 | ⚠️ 会（装到 `/etc/rc.local`） |
| `openwrt/post-sc-update.sh` | ShellCrash 更新后恢复本地补丁 | ⚠️ 会（覆盖 starts/ 下三个文件） |
| `mihomo/*.py` | 诊断 | ❌ 只读 |
| `cdn/*.py` | 诊断 | ❌ 只读 |

「会改什么、怎么改」的机制正本见 [ARCHITECTURE.md](ARCHITECTURE.md)；坑位见 [PITFALLS.md](PITFALLS.md)。
