# 架构与机制

> **一句话**：三个域各管一段 —— **设备侧**（改路由器状态）、**控制面**（只读查 mihomo）、
> **站点侧**（只读测某个站点通不通）；本篇讲清它们的边界、各自**会改什么**、
> 配置从哪来、诊断链路怎么走，是全仓技术事实的**正本**。

---

## 1. 三个域与边界

| 域 | 目录 | 解决什么问题 | 跑在哪 | 能不能写 |
|---|---|---|---|---|
| 设备侧 | [`openwrt/`](../openwrt/) | 代理跑久了会静默劣化：核心假死、出口组被改坏、nft 表掉了、运行态配置被回退 | **路由器上**（busybox ash） | ⚠️ 会，但只做自愈动作 |
| 控制面 | [`mihomo/`](../mihomo/) | 规则到底生效没有？「声明的分组」和「实际命中的分组」是不是同一个？哪个节点握手最快？ | 你的电脑（Python 3.8+） | ❌ 只读 |
| 站点侧 | [`cdn/`](../cdn/) | 某个站点打不开 —— 是 DNS 走了境外、规则没命中 cn 集、还是 CDN 不支持 QUIC？ | 你的电脑（Python 3.8+） | ❌ 只读 |

三者的关系是**串行的一条链**：

```
站点侧 cdn/  ──问「这个域名走哪条路」──▶  控制面 mihomo/  ──问「规则为什么这样生效」──▶  设备侧 openwrt/
     ▲                                                                                        │
     └──────────────── 结论落到设备上改配置 / 切组 ◀───────────────────────────────────────────┘
```

- **站点侧**回答「现象是什么」：某个域名到底走了哪条 DNS 通道、命中了哪条规则、CDN 支不支持 QUIC。
- **控制面**回答「为什么」：把规则按「先匹配先赢」算一遍，指出哪些规则被靠前的宽泛规则遮蔽。
- **设备侧**回答「怎么改」：守护进程负责发现偏离并做最小化修复，离线恢复负责一次性救回链路。

**边界在哪**：控制面与站点侧**永远不替设备侧做决定**。它们只产出结论，
改不改、怎么改由设备侧的脚本按配置执行。

---

## 2. 目录与分层规则

### 2.1 依赖矩阵

| 目录 | 语言 | 允许依赖 | 禁止依赖 |
|---|---|---|---|
| `openwrt/` | POSIX sh（busybox ash） | 设备上的 `curl` `nft` `awk` `sed` `grep` `pidof` `netstat` `df` `nslookup` `crontab` `logger`；ShellCrash 运行时（`start.sh` / `task/task.sh` / `configs/ShellCrash.cfg`） | 任何 Python 文件；任何其它域的目录 |
| `mihomo/` | Python 3.8+（仅标准库；`rule_audit.py` 另需 PyYAML） | 同目录的 `mihomo_api.py` | `openwrt/`；`cdn/` |
| `cdn/` | Python 3.8+（仅标准库） | `../mihomo/mihomo_api.py`（用 `sys.path.insert` 拼出绝对路径） | `openwrt/`；`mihomo/` 的其它模块 |

**唯一允许的跨域依赖**是 `cdn/ → mihomo/mihomo_api.py` 一条。
方向永远是「站点侧 → 控制面」，反方向不允许 —— 控制面不关心具体站点。

### 2.2 为什么 `openwrt/` 与 Python 完全隔离

设备侧脚本要能在**没有 Python 的 busybox 设备上**直接跑。
`openwrt/guardian.sh` 访问控制 API 用的是 `curl` 直接打 HTTP，
不是 `mihomo_api.py`；所以两边对控制 API 的理解（路径、鉴权头）各写一遍。
这是刻意的冗余：**设备侧不能因为 Python 库升级而失效**。

### 2.3 两套配置体系，互不相通

| | 设备侧 `openwrt/` | 控制面 / 站点侧 `mihomo/` `cdn/` |
|---|---|---|
| 载体 | `openwrt/conf/device.conf`（不入库） | 环境变量 |
| 谁读 | 四个 shell 脚本 | 六个 Python 脚本 |
| 典型键 | `AI_GROUP` `CLEAN_GROUP` `NFT_DIR` `NFT_TABLES` | `MIHOMO_API` `MIHOMO_SECRET` `MIHOMO_PROBE_GROUPS` `AUDIT_DIRECT_GROUP` |
| 为什么这样分 | 值是**这台设备**的属性（组名、节点名、表名、路径） | 值是**这次连哪台机器**的属性（地址、密钥、要看的组） |

两侧**不共享配置文件**，也不允许一侧去读另一侧的值。

---

## 3. 配置机制

### 3.1 配置文件查找顺序

四个 shell 脚本用**同一段代码**找配置（`guardian.sh` 第 23–30 行、
`recover-now.sh` 第 18–25 行、`post-sc-update.sh` 第 22–29 行、`rc.local` 第 17–24 行）：

1. 环境变量 `DEVICE_CONF` 指定的文件 —— 命中即用；
2. `<脚本所在目录>/conf/device.conf`；
3. `/etc/openwrt-ops/device.conf`（设备上统一放这里）。

> `rc.local` 的第 2 步回退值是 `/etc` 而不是 `.` ——
> 因为它会被装到 `/etc/rc.local`，脚本目录就是 `/etc`，即 `/etc/conf/device.conf`。
> 其余三个脚本的回退值是 `.`（脚本自己的目录）。

### 3.2 三级优先级：环境变量 > 配置文件 > 内置默认值

优先级不是靠「先设后不设」碰运气，而是**快照—载入—还原**三步
（`guardian.sh` 第 33–49 行）：

1. **快照**：把 `_OPS_VARS` 列出的变量在环境里已存在的值记下来；
2. **载入**：`. "$OPS_CONF"` 把配置文件 source 进来（这会覆盖环境里的值）；
3. **还原**：把第 1 步快照的值写回去。

⇒ **配置文件永远盖不掉环境变量**。想临时改一个值，直接 `export`：

```sh
NFT_TABLES="quicguard" sh openwrt/guardian.sh --dry-run
```

### 3.3 配置文件有语法检查

载入前先 `sh -n "$OPS_CONF"`。**语法错误就整份跳过**，打一行警告，走内置默认值继续跑：

```
警告：配置文件 /etc/openwrt-ops/device.conf 语法错误，已忽略（走默认值）
```

（`rc.local` 的同一行前缀是 `rc.local: 配置文件 ...`。）

这条设计的意思是：**配置写错不会把设备带沟里**，脚本会退化成「什么都没配」的保守状态。

配置文件按 **shell 语法**解析，所以可以带引号、可以写注释。
**只放 `KEY=VALUE`**，不要放命令 —— 它会被 `source` 执行。

### 3.4 占位符默认值 = 「跳过」，不是「判定为配置损坏」

策略组名、节点名这类值的内置默认值是**空字符串**。
每个动作都先判 `[ -n "$XXX" ]` 再做，**空 = 跳过这项自愈**。

这是**有意设计**（见 [SECRETS.md](SECRETS.md) §3）：组名对不上时，
宁可什么都不做，也不要拿一个猜的名字去 PUT 别人的策略组。

### 3.5 设备侧的键 → 哪个脚本会读

不是所有键对所有脚本都有效。下表是按代码逐个核过的：

| 键 | guardian | recover-now | rc.local | post-sc-update | 缺了会怎样 |
|---|---|---|---|---|---|
| `CRASHDIR` | ✅ | ✅ | — | ✅ | 用默认 `/etc/ShellCrash` |
| `RUNTIME_DIR` | ✅ | ✅ | ✅ | ✅ | 用默认 `/tmp/ShellCrash` |
| `CTRL_HOST` | ✅ | — | — | — | 用默认 `127.0.0.1` |
| `CTRL_PORT` | ✅ | ✅ | — | — | 用默认 `9999` |
| `PROXY_PORT` | ✅ | ✅ | — | ✅ | 用默认 `7890` |
| `MIXED_PORT` | — | ✅ | — | ✅ | 用默认 `7892` |
| `DNS_PORT` | — | ✅ | ✅ | — | 用默认 `1053` |
| `CORE_PROC` | ✅ | ✅ | — | ✅ | 用默认 `CrashCore` |
| `NFT_DIR` | ✅ | ✅ | ✅ | — | 用默认 `/etc` |
| `NFT_TABLES` | ✅ | ✅ | ✅ | — | 三处默认值**顺序不同**，见下 |
| `NFT_DNS_TABLES` | — | — | ✅ | — | 用默认 `googleroute` |
| `CRON_FILE` | ✅ | ✅ | — | ✅ | 用默认 `/etc/crontabs/root` |
| `RC_LOCAL` | — | ✅ | — | ✅ | 用默认 `/etc/rc.local` |
| `GUARDIAN_PATH` | — | ✅ | — | ✅ | 用默认 `$CRASHDIR/guardian.sh` |
| `LEGACY_WD` | ✅ | ✅ | — | — | 用默认 `$CRASHDIR/starts/start_legacy_wd.sh` |
| `API_CFG` | ✅ | — | — | — | 用默认 `$CRASHDIR/configs/ShellCrash.cfg` |
| `START_SH` / `TASK_SH` | ✅ | — | — | — | 用默认 `start.sh` / `task/task.sh` |
| `AI_GROUP` / `AI_FALLBACK_GROUP` | ✅ | — | — | — | 留空 → 跳过对应自愈 |
| `CLEAN_GROUP` / `CLEAN_NODE` / `CL_CANDIDATES` | ✅ | ✅ | — | — | 留空 → 跳过 |
| `POOL_GROUP` / `POOL_FALLBACK_GROUP` | ✅ | — | — | — | 留空 → 跳过 |
| `MANUAL_GROUP` | ✅ | — | — | — | 留空 → 不顺着它解析真实出口 |
| `AI_BAD_NODES` / `POOL_BLOCKED_NODES` | ✅ | — | — | — | 留空 → 不判「不可信出口」 |
| `GUARDIAN_LOG` | ✅ | — | — | — | 用默认 `$RUNTIME_DIR/guardian.log` |
| `RECOVER_LOG` | — | ✅ | — | — | 用默认 `/root/recover-last.log` |
| `POST_SC_LOG` | — | — | — | ✅ | 用默认 `/root/post-sc-update.log` |
| `ROUTER_HEALTH_DIR` | — | — | ✅ | — | 用默认 `/etc/router-health` |
| `DNS_WAIT_LOOPS` | — | — | ✅ | — | 用默认 `45`（次） |
| `REBOOT_VERIFY` | — | — | ✅ | — | 用默认 `reboot-verify.sh` |
| `VAR_RUNTIME_DIRS` | — | — | ✅ | — | 用默认那串 `/var/*` |
| `PATCH_DIR` / `PATCH_SPEC` | — | — | — | ✅ | 留空 → 无补丁可恢复 |
| `CHECK_GROUP` | — | — | — | ✅ | 留空 → 跳过「自定义组是否加载」校验 |
| `CORE_BIN` | — | — | — | ✅ | 用默认 `$CRASHDIR/CrashCore.raw` |
| `WARN_INIT_ENABLED` | — | — | — | ✅ | 用默认 `1` |
| 探测地址与阈值（`PROBE_URL` 等） | ✅ | — | — | — | 用脚本内置默认值 |
| 连通性测试地址（`DIRECT_TEST_HOST` / `PROXY_TEST_URL`） | — | ✅ | — | ✅ | 用默认 `www.baidu.com` / `https://www.google.com` |

> **`NFT_TABLES` 的三个默认值不一样**，这不是笔误，是三张表各自的语义不同：
> - `guardian.sh`：`quicguard googleroute googlecn` —— 守护要**补载**的表；
> - `recover-now.sh`：`quicguard googlecn googleroute` —— 恢复时按这个顺序**加载**；
> - `rc.local`：`quicguard googlecn mixedport` —— 开机加载的表；
>   含 DNS 劫持的那张另走 `NFT_DNS_TABLES`，**要等核心 DNS 端口就绪**才加载。

### 3.6 控制面 / 站点侧的环境变量

| 变量 | 谁读 | 默认 |
|---|---|---|
| `MIHOMO_API` | `mihomo_api.py` `latency_probe.py`（其余脚本经 `mihomo_api.py`） | `http://127.0.0.1:9999` |
| `MIHOMO_HOST` / `MIHOMO_PORT` | `mihomo_api.py`（**优先于** `MIHOMO_API`；`latency_probe.py` 不认这两个） | 从 `MIHOMO_API` 拆出来 |
| `MIHOMO_SECRET` | `mihomo_api.py` `latency_probe.py` | `mihomo_api.py`：**无默认，缺了就报错**（第 54–61 行） |
| `MIHOMO_PROBE_GROUPS` | `mihomo_api.py` `latency_probe.py` | `GROUP_A,GROUP_B,GROUP_C` |
| `MIHOMO_PROBE_NODES` | `latency_probe.py` | `NODE_A,NODE_B` |
| `MIHOMO_PROBE_URLS` | `latency_probe.py` | 三个公开 AI 站点 |
| `MIHOMO_RULE_KEYWORDS` / `MIHOMO_RULE_SETS` / `MIHOMO_CONN_KEYWORDS` | `mihomo_api.py` | 规则关键词 / `cn` / 不过滤 |
| `MIHOMO_RULE_PATTERN` | `scan_rules.py` | 不过滤（匹配所有「像域名」的 payload） |
| `MIHOMO_RULE_DNS_HOSTS` | `mihomo_api.py` `dns` 子命令 | `example.com` |
| `AUDIT_*`（直连组 / 广告组 / AI 组 / 推送 / 电报 / 流媒体 / 微软 / 苹果） | `rule_audit.py` | `DIRECT_GROUP` `AD_GROUP` `AI_GROUP` … 通用占位符 |
| `MIHOMO_GROUP_PROXY` / `MIHOMO_GROUP_DIRECT` | `qq_rule_probe.py` | `GROUP_A` / `DIRECT_GROUP` |
| `QQ_CDN_HOSTS` / `QQ_CDN_RESOLVERS` | `qq_cdn_probe.py` | 内置腾讯系域名清单 / 四个公共 DNS |
| `QUIC_PROBE_HOSTS` | `quic_probe.py` | 内置清单 |

**默认值全是通用占位符**（`GROUP_A` / `NODE_A` / `DIRECT_GROUP`）——
照抄别人订阅里的组名会一个都对不上。

---

## 4. 会改什么

> 这一节是**本仓最重要的安全边界**。
> `openwrt/` 下的脚本**会直接改路由器状态**；`mihomo/` 与 `cdn/` **一律只读**。

### 4.1 总览矩阵

| 动作 | `guardian.sh` | `recover-now.sh` | `rc.local` | `post-sc-update.sh` |
|---|---|---|---|---|
| 拉起代理核心 | ✅ §1 | ✅ §3 | — | ✅ §4 |
| 停止 / 强杀核心 | ❌ | ✅ §3 | — | ❌ |
| 重生成运行态配置 | ✅ §5 | ✅ §3 | — | ❌ |
| **切换策略组**（PUT `/proxies`） | ✅ §2 / §2.1 / §2.2 / §3 / §3.5 / §3.6 | ❌ | — | ❌ |
| 加载 nft 表 | ✅ §4 | ✅ §4 | ✅ | ❌ |
| **删除 nft 表** | ❌ | ✅ §2（**仅 DNS 劫持表**） | ❌ | ❌ |
| **重载防火墙**（fw4） | ❌ | ✅ §4.1 | ❌ | ❌ |
| 重启 dnsmasq | ❌ | ✅ §2 | ❌ | ❌ |
| 改 crontab | ✅（只补一行） | ✅（恢复 + 补两行） | ❌ | ✅（补三行） |
| **覆盖上游脚本文件** | ❌ | ❌ | ❌ | ✅ §1 |
| 改写过滤文件 | ❌ | ✅ §1 | ❌ | ❌ |
| 删运行态文件 | ❌ | ✅ §3 | — | ❌ |
| 删 `/tmp` 临时大文件 | ✅ §6 | ❌ | ❌ | ❌ |
| 动网络接口（`ifup`） | ❌ | ✅ §4.1 | ❌ | ❌ |
| 写日志 | ✅ | ✅ | ✅（syslog） | ✅ |
| **重启设备** | ❌ | ❌ | ❌ | ❌ |
| **改订阅 / 规则源文件** | ❌ | ❌ | ❌ | ❌ |
| **改 UCI（`/etc/config/*`）** | ❌ | ❌ | ❌ | ❌ |

### 4.2 `guardian.sh` —— 只做「检测 + 最小化修复」

跑在 cron 里（典型 `*/5 * * * *`），每轮按顺序做下面这些事
（**节号沿用脚本里的编号**，小节是主节之间的插入段）：

| 节 | 检测 | 动作（会改状态） |
|---|---|---|
| 1 核心存活 | `GET /version` 有响应？进程还在？ | 响应就只更新时间戳文件；进程在但 API 没响应 → **只报警不动手**；进程没了且不是人为停的 → `/bin/ash $START_SH start` 拉起，12 秒后复检 |
| 2 AI 出口 | 顺着 `MANUAL_GROUP` 解析真实出口，匹配 `AI_BAD_NODES` | `PUT /proxies/<AI_GROUP>` 切到 `AI_FALLBACK_GROUP` |
| 2.1 兜底组锁干净节点 | 兜底组/干净组的当前选择命中坏节点通配 | `PUT` 切到 `CLEAN_NODE` |
| 2.2 两组入口对齐 | 两个组当前选的不是同一个 | `PUT` 把兜底组对齐到干净组的入口（**只改链路，不改出口**） |
| 3 通用池复位 | 通用池真实出口命中 `POOL_BLOCKED_NODES` | `PUT` 切到 `POOL_FALLBACK_GROUP` |
| 3.5 出口健康 | 经代理连 `PROBE_URL` 两次，取较慢那次 | 超 `EXIT_MAX_SEC` → `PUT` 复位到兜底组 |
| 3.6 干净出口健康 | 经代理连 `CLEAN_PROBE_URL` 两次（带 `--max-filesize 131072`） | 超 `CLEAN_EXIT_MAX_SEC` → 按 `CL_CANDIDATES` 顺序**逐个试**，成功即换；全劣化则**保持原状**并报警，**不降级到不可信节点** |
| 4 nft 表补载 | `nft list table inet <表>` 在不在？ | 缺失且 `$NFT_DIR/<表>.nft` 在 → `nft -f` 加载 |
| 5 静默回退自愈 | 运行态 `config.yaml` 里还有没有兜底组？ | 没有（说明被回退成基础配置了）→ 限频窗口外跑 `/bin/ash $TASK_SH hotupdate` 重生成 |
| 6 探活与水位 | 出口地区码（每小时一次）、`MemAvailable`、`/tmp` 占用 | `/tmp` ≥ `TMPFS_WARN_PCT` → `rm -rf` 白名单里的临时大文件 |
| 收尾 | legacy 看门狗 cron 行还在不在？ | 不在 → 追加一行并 `crontab $CRON_FILE` |

**干跑**：`--dry-run`（或 `-n`）下，上述所有「切组 / 拉起 / 重载 / 改 crontab / 删文件」
一律不执行，只在日志里写「本应……」。**上设备前先干跑。**

### 4.3 `recover-now.sh` —— 一次性救回链路

`sh recover-now.sh`（完整修复）或 `sh recover-now.sh check`（只诊断）。

**注意顺序不能乱**：先让内网直连恢复，再修代理。

| 节 | 动作 |
|---|---|
| 1 | 备份 `$CRASHDIR/configs/fake_ip_filter` → `fake_ip_filter.bak.<时间戳>`，然后去空行 / 注释 / 行尾空白 / 重复项，**原地替换** |
| 2 | **删除** DNS 劫持相关的 nft 表（`DNS_HIJACK_TABLES`），再 `/etc/init.d/dnsmasq restart` → 内网 DNS 回到直连 |
| 3 | 备份 crontab 到 `/tmp/cron.recover.bak` → `sh $CRASHDIR/start.sh stop` → `killall -9 CrashCore` → 删运行态 `config.yaml` / `error.yaml` / `shellcrash.pid` → `sh $CRASHDIR/start.sh start` → 最多等 30 秒 |
| 4 | 按 `NFT_TABLES` 逐张 `nft -f` 加载；并检查 `rc.local` 里有没有第一张表的开机加载 |
| 4.1 | **`/etc/init.d/firewall restart`**（重载 fw4）→ 查 WAN 口地址与默认路由，缺则 `ifup wan` |
| 5 | 从备份恢复 crontab，并补回 `guardian.sh` 与 legacy 看门狗两行 |
| 6 | 校验：端口、`nft list tables`、运行态 `config.yaml` 大小、自定义组在不在、有没有 `error.yaml` |
| 7 | 连通性：内网解析 + 直连 HTTP + 经代理 HTTP（两个地址） |

**日志**：`$RECOVER_LOG`（默认 `/root/recover-last.log`）—— 在 overlay 上，**重启不丢**；
每次运行**开头会被清空**（只留最后一次）。

### 4.4 `rc.local` —— 开机自启模板

装到设备的 `/etc/rc.local`，由 `/etc/init.d/done`（S95）用 `sh /etc/rc.local` 调用，
**早于 S99 的 ShellCrash**。三步：

1. `mkdir -p` 运行时目录 + **兜底重建 `/var` 下的运行时目录**（`VAR_RUNTIME_DIRS`）；
2. 加载**不含** DNS 劫持的 nft 表（`nft list table` 在就跳过 —— 幂等）；
3. **等核心 DNS 端口就绪**（最多 `DNS_WAIT_LOOPS` × 2 秒）再加载**含** DNS 劫持的表；
   等不到就**不加载**，交给守护进程补载。

> 第 3 步是防「内网 DNS 指向一个没人监听的端口」——
> 那正好是「连上 WiFi 但没网」的典型成因。
> 详见 [PITFALLS.md](PITFALLS.md)。

另外：若 `$ROUTER_HEALTH_DIR/.reboot-pending` 存在，会派发开机验收脚本
（`REBOOT_VERIFY`）。

**必须以 `exit 0` 收尾**（上游默认文件就是这样），且每一步都要能重复执行。

### 4.5 `post-sc-update.sh` —— 把本地补丁恢复回来

`sh post-sc-update.sh`（恢复 + 验收）或 `sh post-sc-update.sh check`（只检查）。

1. **恢复补丁**：按 `PATCH_SPEC` 逐项判断 —— 目标文件**同时含有全部标记**就算完好；
   否则从 `PATCH_DIR` 的备份恢复，**官方版另存为 `<文件>.upstream.<时间戳>`**，再 `chmod 755`；
   然后对每个目标文件 `sh -n` 做语法检查。
2. **补 cron 生命线**：`guardian.sh` / `start_legacy_wd.sh` / `task.sh 106` 三行。
3. **启动链路兜底检查**：`rc.local` 里有没有建运行时目录、`guardian.sh` 里有没有 `mkdir` 与 cron 自愈、
   `/etc/init.d/shellcrash` 是不是保持 disabled。
4. **启动**：核心没跑就 `sh $CRASHDIR/start.sh start`，最多等 30 秒。
5. **验收**：`CrashCore.raw -t` 校验运行态配置、统计分组数与规则数、
   查 `CHECK_GROUP` 在不在、再各打一次直连与经代理的 HTTP。

**日志**：`$POST_SC_LOG`（默认 `/root/post-sc-update.log`），同样每次开头清空。

### 4.6 明确不会做的事

四个脚本**共同**不做这些：

- ❌ **不重启设备**（没有 `reboot`）。
- ❌ **不改订阅源文件与规则文件**。
- ❌ **不写 UCI 配置**（`/etc/config/*`）。
- ❌ **不删防火墙链**（`nft delete chain` 一次都没有）——
  唯一的 `nft delete table` 在 `recover-now.sh` §2，且**只删 DNS 劫持表**
  （`DNS_HIJACK_TABLES`），删的正是「让内网 DNS 指向代理」的那几张。
- ❌ **不把流量降级到「不可信」的出口**：`guardian.sh` §3.6 在所有候选都劣化时
  **保持原状**并报警，理由是目标站可能按地区拒绝服务。
- ❌ **不删除任何持久化数据**：`rm -rf` 只出现在两处 ——
  `guardian.sh` §6 删 `/tmp` 白名单里的临时大文件、`recover-now.sh` §3 删运行态的
  `config.yaml` / `error.yaml` / `shellcrash.pid`（**都在 tmpfs 上**）。
- ❌ **不存任何凭据**：控制 API 的 secret 是运行时从
  `$CRASHDIR/configs/ShellCrash.cfg` 的 `secret=` 行**现读**的。

### 4.7 三个域的写权限对比

| | 写设备状态 | 写代理策略 | 写控制台配置 | 写本地文件 |
|---|---|---|---|---|
| `openwrt/` | ✅ | ✅（切组、重生成配置） | ✅（`task.sh hotupdate`） | ✅（日志） |
| `mihomo/` | ❌ | ❌ | ⚠️ **只临时改 `log-level`**（用完改回 `info`） | ✅（报告、findings.json） |
| `cdn/` | ❌ | ❌ | ⚠️ 同上（`qq_domain_classify.py` / `qq_rule_probe.py`） | ❌（只打印） |

`mihomo/` 与 `cdn/` 里那两个改 `log-level` 的动作是**唯一**的写操作，
且都在 `finally` 式的收尾里改回 `info`（见 [PITFALLS.md](PITFALLS.md) 关于它的坑）。

---

## 5. 诊断链路

### 5.1 `mihomo_api.py` 是唯一的控制面访问入口（Python 侧）

它把「怎么跟 mihomo 控制 API 说话」收敛成一处：

| 能力 | 函数 | 说明 |
|---|---|---|
| 建连 | `open_socket(timeout)` | 按 `MIHOMO_HOST` 里有没有 `:` 选 `AF_INET6` / `AF_INET` |
| 请求头 | `host_header()` / `auth_header()` | IPv6 字面量自动加方括号；`Authorization: Bearer <secret>` |
| 原始请求 | `_raw_request()` | 手写 HTTP/1.1 + `Connection: close` + **chunked 解码** |
| 带重试的调用 | `api(path, method, body, tries=12, timeout=15)` | 每次失败隔 0.6 秒重试，12 次后抛 `RuntimeError` |
| DNS 查询 | `dns_query(name, rtype="A")` | 打 `/dns/query` |

**secret 缺失直接报错**（`_secret()`），而不是拿空 secret 去换一个含义不明的 401。

### 5.2 调用关系

```
                              ┌──────────────────────────────┐
                              │   mihomo 控制 API            │
                              │   127.0.0.1:9999（默认）     │
                              └──────────────▲───────────────┘
                                             │
   ┌─────────────────────────────────────────┼──────────────────────────────┐
   │                                         │                              │
   │  Python 侧                              │  Python 侧                    │  设备侧
   │                                         │                              │
┌──┴──────────────┐                 ┌────────┴─────────────┐     ┌──────────┴──────────┐
│ mihomo/         │                 │ cdn/                │     │ openwrt/guardian.sh  │
│  scan_rules.py  │                 │  qq_dns_path.py     │     │  （curl 直连，        │
│  mihomo_log.py  │                 │  qq_domain_classify │     │   不经 Python）       │
│  capture_live.py│                 │  qq_rule_probe.py   │     └──────────┬──────────┘
└──┬──────────────┘                 └────────┬─────────────┘                │
   │                                       │                              │
   └───────────────┬───────────────────────┘                              │
                   │                                                          │
        ┌──────────┴───────────┐                              ┌───────────────┴──┐
        │  mihomo/mihomo_api.py │                              │  ShellCrash 运行时 │
        │  （唯一 Python 入口） │                              │  start.sh /       │
        │  api / dns_query /   │                              │  task/task.sh     │
        │  open_socket / ...   │                              └──────────────────┘
        └──────────────────────┘

  不碰控制 API 的两个例外：
    mihomo/rule_audit.py    —— 纯离线：读 config.yaml + proxies.json 两个文件
    cdn/qq_cdn_probe.py     —— 裸 socket 直连目标站点
    cdn/quic_probe.py       —— 裸 UDP socket，直连目标站点
```

### 5.3 两个例外要说清楚

- **`mihomo/latency_probe.py` 不 import `mihomo_api.py`** —— 它用 `urllib.request` 自己发请求。
  原因是它要对「节点 × 探测目标」做线程池扇出（`ThreadPoolExecutor(max_workers=8)`），
  自己拿 `urllib` 更直接。代价是**行为略有差别**：
  `mihomo_api` 缺 secret 直接抛错，而 `latency_probe` 缺 secret 时**不发鉴权头**，
  服务端返回 401，工具会打印 `HTTP401`。
- **`mihomo/rule_audit.py` 完全离线** —— 它读的是 `config.yaml` 与 `proxies.json`
  两个**文件**，不连控制 API。所以它算的是「配置里声明的规则顺序」，
  **不等于**运行态（运行态的 `cn.mrs` 可能比文本 geosite 滞后，见 [PITFALLS.md](PITFALLS.md)）。

### 5.4 「只读」的具体含义

| 动作 | 允许 | 说明 |
|---|---|---|
| `GET /version` `/configs` `/rules` `/proxies` `/connections` `/dns/query` | ✅ | 纯读 |
| `GET /logs` | ✅ | 只是订阅日志流 |
| `GET /proxies/<组>/delay` | ✅ | 只测握手延迟，不改选择 |
| `PATCH /configs` 改 `log-level` | ⚠️ | **临时改，脚本结束改回 `info`** |
| `PUT /proxies/<组>` 切组 | ❌ | 设备侧 `guardian.sh` 的活 |
| `PATCH /configs` 改端口 / 模式 / DNS | ❌ | 谁都不该在诊断时改这个 |

---

## 6. 相关文档

- [PITFALLS.md](PITFALLS.md) —— 上面提到的每个坑的详细写法。
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) —— 按现象查。
- [MAINTENANCE.md](MAINTENANCE.md) —— 配置模板升级、回归清单、发布流程。
- [UPSTREAM.md](UPSTREAM.md) —— 上游项目与派生边界。
- [SECRETS.md](SECRETS.md) —— 凭据与设备标识的位置索引（只写位置不写值）。
- [`openwrt/README.md`](../openwrt/README.md) —— 设备侧脚本的用法与部署步骤。
