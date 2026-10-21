# 维护流程

> **一句话**：设备配置模板怎么随版本升级、诊断结果留多久、改脚本要回归哪几条、
> 通用版与设备实例怎么同步、发版走哪几步 —— 是全仓维护动作的**正本**。

相关：[DOC-RULES.md](DOC-RULES.md)（文档怎么写、改了要连带改什么）、
[VERSIONING.md](VERSIONING.md)（版本号进位规则）、
[release-notes/README.md](release-notes/README.md)（Release 说明格式）。

---

## 1. 设备配置模板怎么升级

### 1.1 前提：配置分两份，只有样例入库

| 文件 | 入库？ | 说明 |
|---|---|---|
| `openwrt/conf/device.conf.example` | ✅ | **样例**，每次新增键都要更新它 |
| `openwrt/conf/device.conf` | ❌ | 用户自己的那一份，含组名 / 节点名，**永不入库**（`.gitignore` 兜底） |

所以「模板升级」= **只改样例**；用户已有的 `device.conf` **不会被自动更新** ——
这正是要靠 §1.3 的对账流程补上的。

### 1.2 改样例的规矩

1. **新增键一律注释掉**再写（`#KEY=值`），除非它是**必填**的。
   理由：注释掉的键 = 「用内置默认值」，缺了不影响脚本跑。
2. **在分组区写清楚用途**，并注明「留空 = 跳过哪项动作」。
3. **改完对一遍脚本里的默认值**（见 §1.3 的表）——
   样例里的注释值和代码里的默认值**必须一致**，否则用户按样例配出来的行为和默认行为不一样。
4. 改完跑一遍 `sh -n openwrt/conf/device.conf.example`。

### 1.3 新增键时怎么定默认值

> 各键**当前**的默认值与「缺了会怎样」，
> 以及**哪个脚本读哪个键**的完整对照 —— **正本在**
> [ARCHITECTURE.md](ARCHITECTURE.md) §3.5。本节只讲**新增键时的规矩**。

**规矩**：新增键的默认值必须是「空」或「一个通用安全值」，
且**空 = 跳过**，不能是「空 = 判定为配置损坏」——
这是有意的设计（见 [SECRETS.md](SECRETS.md) §3）。

| 键类别 | 该给什么默认值 | 缺了会怎样（设计上） |
|---|---|---|
| 路径类（`CRASHDIR` `NFT_DIR` `RUNTIME_DIR` `*_LOG` …） | 一个**通用**路径（如 `/etc/ShellCrash`、`/etc`、`/tmp/ShellCrash`） | 用默认值，通常仍能跑 |
| 端口类（`CTRL_PORT` `PROXY_PORT` `MIXED_PORT` `DNS_PORT`） | 通用端口（`9999` / `7890` / `7892` / `1053`） | 用默认值 |
| **组名 / 节点名**（`AI_GROUP` `CLEAN_GROUP` `CLEAN_NODE` `CL_CANDIDATES` `POOL_GROUP` `POOL_FALLBACK_GROUP` `MANUAL_GROUP`） | **空** | **对应自愈动作整条跳过** |
| **坏节点通配**（`AI_BAD_NODES` `POOL_BLOCKED_NODES`） | **空** | 不判「不可信出口」，永不自动复位 |
| 探测地址（`PROBE_URL` `CLEAN_PROBE_URL` `CC_PROBE_URL`） | 公开、无需鉴权的地址 | 用默认值 |
| 阈值（`EXIT_MAX_SEC` `CLEAN_EXIT_MAX_SEC` `MEM_LOW_MB` `TMPFS_WARN_PCT` `FALLBACK_HEAL_INTERVAL` `ALIVE_STALE_SEC`） | 一个保守的数值（`3` / `4` / `30` / `80` / `1800` / `1800`） | 用默认值 |
| 目录清单类（`NFT_TABLES` `NFT_DNS_TABLES` `VAR_RUNTIME_DIRS`） | 通用表名 / 通用目录清单 | 用默认值（注意 `NFT_TABLES` 在**三个脚本里默认值不同**） |
| 补丁相关（`PATCH_DIR` / `PATCH_SPEC`） | `$CRASHDIR/local-patches` / **空** | **无补丁可恢复** |
| 校验用（`CHECK_GROUP` `CC_EXPECT`） | **空** | 跳过该项校验 |

### 1.4 用户已有的 `device.conf` 怎么对账

模板升了之后，**用户那份不会自动变**。对账流程：

```sh
# 1) 把新样例和用户配置摆一起看
diff -u openwrt/conf/device.conf.example /etc/openwrt-ops/device.conf

# 2) 新增的键：在用户配置里按样例补一行（不补就用内置默认值）
# 3) 改过默认值的键：确认用户那份的值是不是还合适

# 4) 语法检查
sh -n /etc/openwrt-ops/device.conf

# 5) 干跑看行为
sh openwrt/guardian.sh --dry-run
```

**判断「要不要用户改」的规则**：

| 情况 | 要不要改用户配置 | 理由 |
|---|---|---|
| 新增键，默认值可用 | **不用改** —— 缺了就用默认值 | 缺了 = 跳过某项自愈，不会出错 |
| 新增键，默认值**不可用**（比如组名） | **要改** —— 否则那项自愈永远不生效 | 缺了不是报错，是「静默不工作」 |
| 改动了某个键的默认值 | **要改** —— 用户显式配过的旧值仍然是旧值 | 显式配置优先于默认值，这是设计 |
| 改动了脚本的**行为**（不只是加键） | **要改** —— 行为变更属于破坏性变更 | 按 [VERSIONING.md](VERSIONING.md) §1 要进次版本 |

> ⚠️ **最隐蔽的一种**：新增键的默认值是「空」⇒ 缺了 = 跳过。
> 用户升级后**不会看到任何报错**，只会发现「某项自愈不再发生了」。
> 所以新增键时**务必**在样例里写清「不配会怎样」。

### 1.5 键存在但脚本不读 —— 也要知道

不是所有键对所有脚本都有效。**完整对照**（哪个键被哪个脚本读）
在 [ARCHITECTURE.md](ARCHITECTURE.md) §3.5 —— 那里是**正本**。

维护时要知道的后果：

- 在 `device.conf` 里配了一个键，但**对应脚本不读它** ⇒ **静默无效**：
  配了不报错、也不生效。
- 这不是 bug，是「**一个配置文件服务四个脚本**」的必然结果。
- 典型形态：某个键在 A 脚本里是**路径类默认值**、在 B 脚本里是**空**——
  同一行配置对两个脚本的含义完全不同。
- 还有一类是**声明了但没被任何逻辑读取**的键（历史遗留的开关），
  配它等于没配。

⇒ **改脚本时如果动了某个键的使用方式（新增、删除、改默认、改引用），
要回来更新 [ARCHITECTURE.md](ARCHITECTURE.md) §3.5 的那张表**，
否则排查时会被这张过时的表带偏。

---

## 2. 诊断结果与日志的保留策略

### 2.1 落点一览

| 产物 | 落点 | 介质 | 重启会丢吗 | 会自动清吗 |
|---|---|---|---|---|
| 守护日志 | `$GUARDIAN_LOG`（默认 `/tmp/ShellCrash/guardian.log`） | tmpfs | ✅ 丢 | 超过 200 KB 截成**最后 60 行** |
| 离线恢复日志 | `$RECOVER_LOG`（默认 `/root/recover-last.log`） | overlay | ❌ 留 | ✅ **每次运行开头清空**（只留最后一次） |
| 补丁恢复日志 | `$POST_SC_LOG`（默认 `/root/post-sc-update.log`） | overlay | ❌ 留 | ✅ 每次运行开头清空 |
| 过滤文件备份 | `$CRASHDIR/configs/fake_ip_filter.bak.<时间戳>` | overlay | ❌ 留 | ❌ **不会自动清**（会累积） |
| 官方版留档 | `$CRASHDIR/<文件>.upstream.<时间戳>` | overlay | ❌ 留 | ❌ 不会自动清（会累积） |
| 恢复期的 crontab 备份 | `/tmp/cron.recover.bak` | tmpfs | ✅ 丢 | ❌ |
| 实时日志抓取 | `capture_live.py <输出文件>` —— **你自己指定** | 本地磁盘 | ❌ 留 | ❌ |
| 规则审计报告 | `rule_audit.py` 的第 4 个参数（`REPORT.md`）—— 你指定 | 本地磁盘 | ❌ 留 | ❌ |
| 审计机读结果 | `findings.json` —— **落在当前目录**（硬编码） | 本地磁盘 | ❌ 留 | ❌ |
| 守护自愈的时间戳文件 | `$RUNTIME_DIR/.proxy_alive` `.last_fallback_heal` `.cc_probe_ts` | tmpfs | ✅ 丢 | ❌ |

### 2.2 保留规则

1. **仓内不留运行产物**。`.gitignore` 已经挡掉
   `*.log` `*.bak` `*.tmp` `report*.md` `REPORT*.md` `findings*.json` `*.pid`。
   新增工具产物时**顺手加一条**。
2. **设备上默认只留「最后一次」**：恢复类脚本的日志每次开头清空，
   够用；不够用就**当场拷走**，别指望它留。
3. **备份类文件「改完即删」**：设备上那两类**会累积**的备份
   （`fake_ip_filter.bak.*` 与 `*.upstream.*`）是明确要手工清的 ——
   它们每个都是一份完整的配置 / 脚本副本，放久了白占闪存。
   清的判据：**当前状态已经确认没问题**。
4. **要长期留的证据，另指到 overlay 路径**。比如把 `GUARDIAN_LOG`
   指到 `/root/` 下的一个文件，而不是让它待在 tmpfs 上等重启。
5. **本地电脑上的抓取产物自己管**：`capture_live.py` 默认抓 1200 秒、
   每条立即落盘 —— 一场排查的量不小，别在系统盘上随手堆。

### 2.3 查日志的顺序

| 你要看的 | 看哪儿 | 注意 |
|---|---|---|
| 守护最近干了什么 | `$GUARDIAN_LOG`（**全量**） | 别看 `logread` |
| 守护的告警 | `logread \| grep guardian` | 只有含 `FIX`/`ALERT`/`ERROR`/`WARN` 的行会进 syslog |
| 一次恢复的完整过程 | `$RECOVER_LOG` | **只有最后一次**，要留就当场拷 |
| 一次补丁恢复的完整过程 | `$POST_SC_LOG` | 同上 |
| 代理的实时决策 | `mihomo_log.py` / `capture_live.py` | 前者会临时改日志级别（用完改回 `info`），后者不会 |
| 一次抓包的原始日志 | `capture_live.py` 的输出文件 | 追加模式（`a`），多次跑会接在一起 |

---

## 3. 脚本改动的回归清单

> 通用前置：改完先跑
> `for f in $(find openwrt -name '*.sh'); do sh -n "$f"; done`、
> `python3 -c "import ast,glob; [ast.parse(open(f,encoding='utf-8').read(), f) for f in glob.glob('**/*.py', recursive=True)]"`、
> `python3 tools/check-docs.py`。
> shell 脚本**必须 LF 换行** —— CRLF 在 busybox 下直接报 `bad interpreter`。

### 3.1 改了 `openwrt/guardian.sh`

| # | 回归项 | 怎么验 |
|---|---|---|
| G1 | **干跑不产生任何副作用** | `sh guardian.sh --dry-run`，前后比对：策略组选择、nft 表集合、crontab 内容、`/tmp` 文件 —— 全部不变 |
| G2 | **干跑与实跑的动作集合一致** | 干跑日志里每条「本应……」在实跑里都有对应动作 |
| G3 | **配置优先级四态** | ① `DEVICE_CONF=/path/x` ② 脚本同目录 `conf/device.conf` ③ 环境变量覆盖配置文件 ④ 配置文件语法错误 → 打警告并走默认值 |
| G4 | **空配置不误动作** | 清空所有组名 / 节点名跑一轮 —— 不应出现任何 `FIX` |
| G5 | **幂等** | 连跑两遍，第二遍不产生新的 `FIX`（除了限频窗口外） |
| G6 | **坏节点通配按预期命中** | 用 `\|` 分隔的通配造一个假组名，验证命中与不命中 |
| G7 | **限频窗口生效** | 回退自愈（`FALLBACK_HEAL_INTERVAL`）与地区码探测（3600 秒）不能连着触发 |
| G8 | **日志自限容** | 日志超 200 KB 后只剩最后 60 行 |
| G9 | **crontab 补回不重复** | 已有 legacy 行时不再追加 |

### 3.2 改了 `openwrt/recover-now.sh`

| # | 回归项 | 怎么验 |
|---|---|---|
| R1 | **`check` 模式零副作用** | 跑 `check` 前后比对：nft 表集合、配置文件内容、crontab、进程 —— 全不变 |
| R2 | **顺序正确** | 摘 DNS 劫持 → 重启 dnsmasq → 停核心 → 清运行态 → 起核心 → 加载表 → 重载防火墙 → 恢复 crontab |
| R3 | **过滤文件清洗正确** | 备份文件生成；空行 / 注释 / 行尾空白 / 重复项被清掉；**内容行没被误删** |
| R4 | **修复后自检全绿** | 端口在、nft 表在、`config.yaml` 存在、无 `error.yaml`、crontab 三行在 |
| R5 | **crontab 恢复后不丢行** | `task.sh 106` 那行也在（它负责保存面板选择） |
| R6 | **WAN / 默认路由兜底** | 无 WAN 地址或无默认路由时会 `ifup wan` |
| R7 | **日志每次清空** | 连跑两次，第一次的日志不残留 |

### 3.3 改了 `openwrt/rc.local`

| # | 回归项 | 怎么验 |
|---|---|---|
| C1 | **以 `exit 0` 收尾** | 文件最后一行必须是 `exit 0` |
| C2 | **幂等** | 连跑两次，`nft list tables` 的输出不变（`load_nft_table` 先查在不在） |
| C3 | **DNS 表的等待逻辑** | 核心**没起来**时，含 DNS 劫持的表**不加载**，只记 syslog |
| C4 | **`/var` 兜底目录全建出来** | 逐个 `ls -d` |
| C5 | **运行时目录建出来** | `/tmp/ShellCrash` 存在 |
| C6 | **开机验收派发** | 放一个 `.reboot-pending` 标记，验证验收脚本被调起 |
| C7 | **LF 换行** | `file` 或 `grep -c $'\r'` |

### 3.4 改了 `openwrt/post-sc-update.sh`

| # | 回归项 | 怎么验 |
|---|---|---|
| P1 | **`check` 模式零副作用** | 不恢复文件、不补 cron、不启动核心 |
| P2 | **标记判定三态** | 含全部标记 → `OK`；缺标记且有备份 → 恢复；缺标记且无备份 → 报缺 |
| P3 | **官方版留档** | 恢复后 `$CRASHDIR/<文件>.upstream.<时间戳>` 存在且是官方版 |
| P4 | **权限位** | 恢复后 `chmod 755` 生效 |
| P5 | **语法检查输出** | 每个目标文件都有 `语法 OK` 或 `语法错误` 的结论 |
| P6 | **cron 三行补齐且不重复** | `guardian.sh` / `start_legacy_wd.sh` / `task.sh 106` |
| P7 | **启动链路检查项** | `rc.local` 的 `mkdir -p`、`guardian.sh` 的 `mkdir` 与 `cron lifeline`、`init.d/shellcrash` 保持 disabled |
| P8 | **验收段** | `CrashCore.raw -t` 通过；分组数 / 规则数有输出 |

### 3.5 改了 `mihomo/mihomo_api.py`

| # | 回归项 | 怎么验 |
|---|---|---|
| A1 | **所有引用方仍能 import** | `mihomo/scan_rules.py` `mihomo/mihomo_log.py` `mihomo/capture_live.py` `cdn/qq_dns_path.py` `cdn/qq_domain_classify.py` `cdn/qq_rule_probe.py` |
| A2 | **缺 secret 明确报错** | 不设 `MIHOMO_SECRET` 运行 → 抛 `RuntimeError`，不是 401 |
| A3 | **IPv6 主机** | `MIHOMO_HOST='::1'` 时 Host 头是 `[::1]:9999` |
| A4 | **chunked 解码** | 对返回 chunked 的路径，结果能被 `json.loads` 解析 |
| A5 | **重试与超时** | 端点不通时按 `tries` 次数重试后抛错；不要把 `tries` 调小到掩盖真实故障 |
| A6 | **子命令全通** | `summary` `proxies` `rulestats` `conns` `dns` `delay` `raw` 逐个跑一遍 |

### 3.6 改了 `mihomo/rule_audit.py`

| # | 回归项 | 怎么验 |
|---|---|---|
| Q1 | **能跑完** | 产出 `REPORT.md` 与 `findings.json`（后者落在**当前目录**） |
| Q2 | **代表域名回归** | 报告 §6 的异常项为 0；异常项要逐个确认是「有意覆盖」还是「顺序副作用」 |
| Q3 | **严重改道条数** | 报告 §3.1 的行数不异常增长（每一条都要有人认领） |
| Q4 | **MATCH 之后无规则** | 报告里 `MATCH 之后的规则` 应为 0 |
| Q5 | **组名全走环境变量** | 脚本里搜不到任何具体组名 |

### 3.7 改了 `cdn/` 下任一脚本

| # | 回归项 | 怎么验 |
|---|---|---|
| D1 | **不改任何设备 / 代理状态** | 只允许 `PATCH /configs` 改 `log-level` |
| D2 | **日志级别用完恢复** | `qq_domain_classify.py` / `qq_rule_probe.py` 结束时 `log-level` 回到 `info` |
| D3 | **只读连接** | 只有 `GET`；`mihomo_api.api()` 的 `method` 参数除 `log-level` 外不传 `PATCH` |
| D4 | **`quic_probe.py` 对照站点** | 清单里国内与国外各一个对照站，结论不同才说明是链路问题 |
| D5 | **`qq_cdn_probe.py` 三段可分辨** | `dns` / `probe` / `all` 各自输出正确 |

### 3.8 改完还要连带改的

按 [DOC-RULES.md](DOC-RULES.md) §5 的**变更触发矩阵**：

| 改了什么 | 必须同步 |
|---|---|
| 改了脚本行为 | 仓库根 [README.md](../README.md) 的文件清单表、对应文档的描述 |
| 改了配置键 | `openwrt/conf/device.conf.example`、[ARCHITECTURE.md](ARCHITECTURE.md) §3.5 的键表、**本篇 §1.3** |
| 新增 / 删除 / 改名文件 | 仓库根 [README.md](../README.md) 的目录结构与文件清单表 |
| 新增 / 删除 / 改名文档 | [docs/README.md](README.md) 索引 |
| 改了踩坑行为 | [PITFALLS.md](PITFALLS.md) |
| 改了排障步骤 | [TROUBLESHOOTING.md](TROUBLESHOOTING.md) 的对应节 |
| 改了凭据位置 | [SECRETS.md](SECRETS.md) 与 `.gitignore` |
| 改了发版规则 | [VERSIONING.md](VERSIONING.md) |

---

## 4. 通用版与设备实例的同步

### 4.1 两边是什么关系

| | 本仓（`OpenwrtOpsToolkit`） | 设备实例（私有仓） |
|---|---|---|
| 定位 | **通用版** —— 任何 OpenWrt 都能用 | **这台设备实际在跑的那份** |
| 设备相关的值 | **读配置**（`device.conf`） | 写死在脚本里 |
| 干跑模式 | 有（`--dry-run` / `check`） | 无 |
| 是否在跑 | ❌ 不在路由器上跑 | ✅ 已经部署在路由器上 |

> 设备实例那一份**已经在路由器上跑着**，所以它是**复制**不是**移动** ——
> 搬走会让「设备上跑的」与「仓库里记的」对不上。

### 4.2 差异点

| 项 | 设备实例 | 通用版（本仓） |
|---|---|---|
| 策略组名 | 写死 | 读 `AI_GROUP` / `AI_FALLBACK_GROUP` / `CLEAN_GROUP` / `POOL_GROUP` / `POOL_FALLBACK_GROUP` / `MANUAL_GROUP` |
| 节点名 | 写死 | 读 `CLEAN_NODE` / `CL_CANDIDATES` / `AI_BAD_NODES` / `POOL_BLOCKED_NODES` |
| nft 表 | 写死路径 | 读 `NFT_DIR` / `NFT_TABLES` / `NFT_DNS_TABLES` |
| 自建目录 | 写死 | 读 `ROUTER_HEALTH_DIR` |
| 端口 | 写死 | 读 `CTRL_PORT` / `PROXY_PORT` / `MIXED_PORT` / `DNS_PORT` |
| 配置加载 | 无 | 环境变量 → `device.conf` → 内置默认值；`DEVICE_CONF` 指定路径 |
| 干跑 | 无 | `guardian.sh --dry-run`、`recover-now.sh check`、`post-sc-update.sh check` |
| API secret | 从 `configs/ShellCrash.cfg` 现读 | 同（**两边都不存凭据**） |

### 4.3 改动方向

**先改通用版 → 再同步设备实例。**

- 设备实例的改动若涉及**通用逻辑**（流程、判断顺序、错误处理），
  **必须**回到通用版改一遍 —— 否则通用版会慢慢落后于设备上跑的那份。
- 反向**不成立**：通用版为「适配更多设备」做的泛化
  （比如把节点清单变成配置项）**不必**回灌实例 ——
  实例写死反而更直观，也更不容易被一份写错的配置带偏。

### 4.4 差异记录在哪

| 内容 | 位置 |
|---|---|
| **差异点表与改动方向** | 设备实例仓的 `docs/UPSTREAM.md` §7「通用版与设备实例的分工」——**正本在那儿** |
| 本仓这一侧的说明 | 本篇 §4（**一句话 + 指向正本的链接**） |
| 通用版自身的来源 | 仓库根 [PROGRESS.md](../PROGRESS.md)（建仓与迁出的批次日志） |
| 迁出过程与决策 | 私有仓的 `PROGRESS.reorg.md` |
| 本仓的上游与派生边界 | [UPSTREAM.md](UPSTREAM.md) |

> 同步目前是**手工对拍**，没有自动化。
> 本仓 `PROGRESS.md` 的「待解决的问题」里记着这一条 ——
> **要定同步机制时，改那一条，别在两处各写一份规则**。

---

## 5. 版本发布流程

### 5.1 三处必须一致

按 [VERSIONING.md](VERSIONING.md)：

| 位置 | 内容 |
|---|---|
| 仓库根 [CHANGELOG.md](../CHANGELOG.md) | **版本号本身**只在这里维护（段标题形如 `## [0.1.0] — 2026-10-20`） |
| `docs/release-notes/<版本>.md` | 面向使用者的 Release 说明，**文件名 = 版本号** |
| 发版 tag | `v<版本>` 形式，tag 名 = 版本号 |

### 5.2 步骤

1. **攒改动**：`CHANGELOG.md` 顶部的 `## [未发布]` 段，按对象一行一条地追加。
2. **判版本号**：按 [VERSIONING.md](VERSIONING.md) §1–§2 ——
   **有功能更新进次版本（+0.1.0，补丁归零）**；
   **没有功能更新进补丁版本（+0.0.1）**；
   **只改文档 / 只改 CI → 根本不动版本号**。
3. **写 Release 说明**：新建 `docs/release-notes/<版本>.md`，
   格式严格按 [release-notes/README.md](release-notes/README.md) ——
   **清单不是文章**、动词四个（新增 / 调整 / 修复 / 优化）、
   **凡本版改过的东西都要有一行**、结尾是固定尾巴。
4. **改段标题**：把 `## [未发布]` 改成 `## [<版本>] — <发版日期>`。
5. **打 tag**：`v<版本>`。
6. **贴 Release**：把 `docs/release-notes/<版本>.md` 贴进 Release 页面。
   按 [release-notes/README.md](release-notes/README.md) 的约定，
   本仓**未接入自动发布流水线**，这一段是手工的；流水线接入后要重写那段。

### 5.3 发版前自检

```bash
# 语法
for f in $(find openwrt -name '*.sh'); do sh -n "$f"; done
python3 -c "import ast,glob; [ast.parse(open(f,encoding='utf-8').read(), f) for f in glob.glob('**/*.py', recursive=True)]"

# 文档（链接 / 锚点 / 一句话引言块 / 孤儿）
python3 tools/check-docs.py

# 凭据扫描
git diff --cached | grep -nE 'oc_sk_|SECRET *= *"[0-9a-f]{16,}|password *= *"[^"]{4,}"'

# 设备配置没入库
test ! -e openwrt/conf/device.conf
```

CI（`.github/workflows/ci.yml`）跑的就是这几样，外加一条明文凭据扫描。

### 5.4 破坏性变更要显式标注

配置格式不兼容、脚本调用方式变了、目标路径变了 ——
这三种按 [VERSIONING.md](VERSIONING.md) §1 属**破坏性变更**：
**进次版本**，并且在 CHANGELOG 的版本段落里**显式标注**，
同时在 Release 说明的「注意」区块里写清「怎么迁」。

**「注意」区块能不写就不写** —— 只有「你不知道就会出问题」的事才写。

---

## 6. 相关文档

- [ARCHITECTURE.md](ARCHITECTURE.md) —— 键 → 脚本的完整对照表（§3.5）、每个脚本会改什么（§4）。
- [PITFALLS.md](PITFALLS.md) —— 改脚本时最容易踩回来的那些坑。
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) —— 改完怎么验证行为。
- [UPSTREAM.md](UPSTREAM.md) —— 上游与派生边界。
- [SECRETS.md](SECRETS.md) —— 凭据位置索引。
