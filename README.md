<div align="center">

<img src="assets/logo.png" width="128" alt="OpenWrt 运维工具箱">

</div>

# OpenwrtOpsToolkit

> **可见性**：公开 —— 仓内**零凭据、零设备标识**；所有设备相关的值都走配置文件或环境变量。
> 第三方组件声明见 [NOTICE](NOTICE)。

> **一句话**：给 **OpenWrt 与 mihomo** 用的**运维工具箱** —— 设备侧守护与离线恢复脚本、
> mihomo 控制面诊断工具、站点可达性专项排查工具，都是**能直接拿去用**的。

三个域：

| 目录 | 干什么 | 适合谁 |
| --- | --- | --- |
| [`openwrt/`](openwrt/) | 设备侧运维脚本：网络守护、离线恢复、开机自启模板、ShellCrash 补丁恢复 | 自己在 OpenWrt 上跑透明代理的人 |
| [`mihomo/`](mihomo/) | mihomo 控制面诊断：规则审计、实时日志、连接快照、节点延迟 | 用 Clash.Meta / mihomo 内核的人 |
| [`cdn/`](cdn/) | 站点可达性专项：CDN 连通性、DNS 路径、规则命中、QUIC 能力 | 排查"某个站点打不开/被限速"的人 |

---

## 这是什么

这套工具解决的是**同一类问题的三个侧面**：

- **设备侧**（`openwrt/`）：代理跑久了会静默劣化 —— 出口组被改坏、nft 表掉了、核心假死。
  守护进程负责发现并做**最小化修复**；离线恢复脚本负责在"连得上 WiFi 但没网"时把链路救回来。
- **控制面**（`mihomo/`）：规则到底生效了没有？"声明的分组"和"实际命中的分组"是不是一致？
  哪个节点握手最快？这些都能离线查，不用改任何配置。
- **站点侧**（`cdn/`）：某个站点打不开，是 DNS 走了境外、规则没命中 cn 集、还是 CDN 不支持 QUIC？
  三个环节分开测，结论才站得住。

**设计原则**：能只读就只读（`mihomo/` `cdn/` 全部只读，不切组不改配置）；
要动手的（`openwrt/`）一律**做最小化修复**，绝不删防火墙链、绝不重启设备、绝不改订阅。

---

## 适用环境

| 项 | 要求 |
| --- | --- |
| 设备 | 任意 OpenWrt（需 `uhttpd` / `ubus` / `rpcd`；`openwrt/` 还需要 `nft` / `busybox sh`） |
| 代理 | ShellCrash 或任何基于 **Clash.Meta / mihomo** 内核的部署 |
| 本机工具 | `mihomo/` `cdn/` 需要 **Python 3.8+**（只依赖标准库，**除** `mihomo/rule_audit.py` 需要 `PyYAML`）；`openwrt/` 是纯 shell |
| 网络 | 诊断类工具需要能连到 mihomo 控制 API（默认 `http://127.0.0.1:9999`） |

> **已验证环境**：小米 AX3000T / OpenWrt 25.12.6 / mihomo v1.19.32 / ShellCrash。
> 那是**验证环境**，不是支持范围 —— 脚本只依赖上面列的那些通用能力。

---

## 快速开始

### 1. 拿配置

```sh
git clone <本仓>
cd OpenwrtOpsToolkit
cp openwrt/conf/device.conf.example openwrt/conf/device.conf
# 按你的环境改：策略组名、节点名、nft 表路径
```

### 2. 跑诊断（只读，不改任何配置）

```sh
# 规则审计：13k 条规则里，哪些被遮蔽了、哪些指向了错的组
# （这个脚本要解析 mihomo 的 config.yaml，需要 PyYAML：pip install pyyaml）
python3 mihomo/rule_audit.py <config.yaml> <proxies.json> <lists目录> REPORT.md

# 控制面连通性与节点延迟
MIHOMO_API=http://127.0.0.1:9999 MIHOMO_SECRET=xxx python3 mihomo/latency_probe.py
```

### 3. 装守护（会改设备状态，先读 docs/ARCHITECTURE.md）

```sh
# 拷到路由器并试跑
scp openwrt/guardian.sh root@<路由器IP>:/etc/ShellCrash/guardian.sh
ssh root@<路由器IP> 'sh /etc/ShellCrash/guardian.sh --dry-run'
```

---

## 目录结构

```
openwrt-ops-toolkit/
├─ openwrt/
│  ├─ guardian.sh            网络守护：出口组复原 / nft 表补载 / 探活
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
│  └─ quic_probe.py         QUIC 能力探测
├─ tools/check-docs.py       文档自检（链接 / 锚点 / 引言块 / 孤儿）
├─ docs/                    文档（README.md 是唯一索引）
├─ memories/                记忆文档：踩过的坑与实测结论
└─ assets/                   logo
```

---

## 文件清单

| 文件 | 作用 | 会改设备状态吗 |
|---|---|---|
| `openwrt/guardian.sh` | 每 5 分钟巡检一次，必要时做最小化修复 | ⚠️ 会（但只做自愈动作） |
| `openwrt/recover-now.sh` | 手动触发的成套恢复 | ⚠️ 会（重生成配置、重载 fw4） |
| `openwrt/rc.local` | 开机自启模板 | ⚠️ 会（装到 `/etc/rc.local`） |
| `openwrt/post-sc-update.sh` | ShellCrash 更新后恢复本地补丁 | ⚠️ 会（覆盖 starts/ 下三个文件） |
| `mihomo/*.py` | 诊断 | ❌ 只读 |
| `cdn/*.py` | 诊断 | ❌ 只读 |

---

## 配置与凭据

**所有设备相关的值都在 `openwrt/conf/device.conf` 里**，脚本的读取顺序是
**环境变量 → 配置文件 → 占位符默认值**。配置文件本身不入库（见 `.gitignore`），
样例 `device.conf.example` 入库。

凭据一律走环境变量：

| 变量 | 用途 |
|---|---|
| `MIHOMO_API` | mihomo 控制 API 地址（默认 `http://127.0.0.1:9999`） |
| `MIHOMO_SECRET` | mihomo 控制 API 的 secret |
| `DEVICE_CONF` | `device.conf` 的路径 |

位置索引见 [docs/SECRETS.md](docs/SECRETS.md)。

---

## 已知坑

- **`/tmp` 是内存盘**（OpenWrt 通用）—— 别往里放大文件；内核测试文件能把它撑爆。
  详见 [docs/PITFALLS.md](docs/PITFALLS.md)。
- **Redir 模式只代理 TCP** —— UDP 全部直出，QUIC 会绕过透明代理。
  详见 [docs/PITFALLS.md](docs/PITFALLS.md)。
- **规则"声明"不等于"生效"** —— 靠前的宽泛规则会遮蔽靠后的具体规则。
  `mihomo/rule_audit.py` 专门算这个。
- **节点/策略组名是配置，不是常量** —— 本仓的脚本不写死任何组名，全在 `device.conf`。

---

## 参与与治理

- [CONTRIBUTING.md](CONTRIBUTING.md) —— 怎么跑、改代码守什么规矩、提交前要跑的自检
- [SECURITY.md](SECURITY.md) —— 安全问题怎么报、脚本会改哪些设备状态
- [docs/README.md](docs/README.md) —— 文档唯一索引
- CI：`.gitlab-ci.yml`（shell / python 语法 + 文档自检）

---

## 许可证

MIT —— 全文见 [LICENSE](LICENSE)。

> 本仓的脚本**会修改路由器状态**。在别人的设备上用之前，请先读
> [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) 的「会改什么」一节。
