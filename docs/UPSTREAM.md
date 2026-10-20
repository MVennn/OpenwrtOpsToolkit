# 上游与派生边界

> **一句话**：本仓**不装上游、不分发上游**（除了被本地补丁改过的
> ShellCrash `starts/` 脚本）—— 本篇讲清**用到哪些上游、哪些文件算派生件、
> MIT 与 GPL-3.0 怎么共存、以及怎么跟着上游更新**。

法律与第三方声明的**正本在仓库根 [NOTICE](../NOTICE)**，
许可证全文在 [LICENSE](../LICENSE)。本篇只讲**技术边界**，
不重复声明的全文。

---

## 1. 上游清单

| 上游 | 仓库 | 许可证 | 本仓怎么用它 | 随仓分发？ |
|---|---|---|---|---|
| **ShellCrash** | https://github.com/juewuy/ShellCrash | GPL-3.0 | 设备侧的运行时：`start.sh` / `task/task.sh` / `starts/*` / `configs/ShellCrash.cfg` | ❌ 不分发本体 |
| **mihomo / Clash.Meta** | https://github.com/MetaCubeX/mihomo | MIT | 控制 API、`config.yaml` 结构、规则语义；`mihomo/` 全部工具对着它说话 | ❌ 不分发本体与二进制 |
| **OpenWrt** | https://openwrt.org | GPL-2.0（基础系统） | 固件本身：`rc.local` 约定、nftables 子系统、busybox shell | ❌ 不分发 |
| **MetaCubeX meta-rules-dat** | https://github.com/MetaCubeX/meta-rules-dat | GPL-3.0 | geosite / geoip 分类数据集 | ❌ **只引用来源地址，不分发数据** |
| **nftables** | https://nftables.org | GPL-2.0（内核侧） | 自建 nft 表的语法与语义 | ❌ 不分发 |

**本仓自己的代码**（四个 shell 脚本 + 六个 Python 脚本 + 文档）
**全部是原创的**，按 [LICENSE](../LICENSE) 的 **MIT** 发布。

> ⚠️ **许可证一栏要跟着上游复核**。上表是本仓建仓时（2026-10-20）的判断；
> 每次跟上游更新时，顺手看一眼上游仓库当前的 LICENSE，
> 有变化就改 [NOTICE](../NOTICE) 与本表。

---

## 2. 打补丁派生件

### 2.1 什么是「派生件」

**派生件 = 拿上游文件改了内容**。本仓里只有一类：

> ShellCrash `starts/` 目录下**被本地改过**的脚本。

被改的原因很具体：ShellCrash 的 `starts/` 脚本负责「生成配置之后做后处理」，
而规则重组、分组排序、CN 中间层插入这些动作**必须**落在那个位置 ——
改在别的地方不生效（上游的 `merger_yaml` 之后、`test_yaml` 之前）。

### 2.2 机制：`post-sc-update.sh` 的「标记 + 备份」

官方更新会**整包覆盖** `starts/` `libs/` `tools/`，
你打的补丁会被**静默冲掉**（没有任何报错）。
本仓的对策是 `openwrt/post-sc-update.sh`：

```
PATCH_SPEC 格式：  <相对 CRASHDIR 的路径>=<标记1>,<标记2>
```

- **路径** —— 相对 `$CRASHDIR` 的路径，例如 `starts/xxx.sh`；
- **标记** —— 文件里必须**同时含有**的字符串（标记之间是**与**关系），
  用来判断「这个文件还是不是打过补丁的那份」。

判定与动作：

| 情况 | 动作 |
|---|---|
| 目标文件**含有全部标记** | `OK` —— 不用管 |
| 缺标记，但 `PATCH_DIR` **有备份** | 从备份恢复；**官方版另存为 `<文件>.upstream.<时间戳>`**；`chmod 755` |
| 缺标记，`PATCH_DIR` **没备份** | 报「缺标记且没有备份」—— 需要手工重打补丁 |
| 恢复后 | 对每个目标文件跑 `sh -n` 做语法检查 |

⇒ **标记是这套机制的命脉**：标记写在被打补丁的代码里，
上游更新冲掉补丁 → 标记消失 → 判定为「需要恢复」。

### 2.3 派生件清单

参考部署里被补丁覆盖到的文件分两类，**许可证不同**：

| 类别 | 例子 | 是什么 | 许可证 | 判定依据 |
|---|---|---|---|---|
| **上游文件被本地改过** | `starts/clash_modify.sh` | 上游的「生成配置后处理」脚本，本地插了钩子 | **GPL-3.0**（保留上游版权头） | 文件头保留上游的 `Copyright` 行与 GPL-3.0 声明 |
| **自有钩子脚本** | `reorder-groups.sh`、`rules-mid.sh` | 本仓/实例**自写**的脚本，放在 ShellCrash 目录里供上游脚本调用 | MIT | 文件头是自写的用途说明，没有上游版权声明 |

> **放哪不重要，重要的是「是不是上游的文件改的」**。
> 判定方法只有一个：**看文件头有没有上游的版权声明** ——
> 有 = 派生件（GPL-3.0）；没有 = 自有内容（MIT）。
>
> ⚠️ **当前状态**：`PATCH_SPEC` 的**具体条目与标记还没最终定稿** ——
> 标记语法（`路径=标记1,标记2`，与关系）需要按实际补丁再校一遍。
> 这条待办记在设备实例仓的 `PROGRESS.reorg.md` 遗留节里。

### 2.4 边界：哪些**不是**派生件

| 不是派生件 | 原因 |
|---|---|
| `openwrt/guardian.sh` 等四个 shell 脚本 | **从零写的**，只用 ShellCrash 的**接口**（路径、命令、子命令名） |
| `mihomo/` 六个 Python 脚本 | 从零写的，只对着 mihomo 的**HTTP 接口**说话 |
| `openwrt/conf/device.conf.example` | 纯配置样例 |
| 文档 | 原创 |

**「接口名是事实，引用不改归属」** ——
脚本里出现 `/etc/ShellCrash/start.sh`、`task.sh hotupdate`、`/configs` 这些字符串，
**不构成**对上游代码的复制。照着接口写调用，跟复制代码是两件事。

---

## 3. MIT 与 GPL-3.0 怎么共存

### 3.1 结论

**成立**，因为这是**并列聚合（mere aggregation）**，不是链接：

- 本仓的 MIT 代码**不包含、不链接、不派生自**任何 GPL-3.0 文件；
- GPL-3.0 的派生件（被改过的 `starts/` 脚本）**独立存在**，
  保留上游版权头，按 GPL-3.0 分发；
- 两者放在同一个设备、同一个目录里，**互不传染**。

### 3.2 三条硬规矩

1. **复制上游代码段 = 变成派生件**。
   本仓任何文件都不许「抄一段 ShellCrash 的 shell 再改」而不标注来源与许可证。
   —— 现状是四个设备侧脚本全部从零写，只用接口。
2. **派生件必须保留上游版权头**。
   被补丁的 `starts/` 脚本**保留上游原有的 `Copyright` 行与 GPL-3.0 声明**，
   本地改动以注释标出（`# 本地补丁：…`）。
   `post-sc-update.sh` 的恢复动作是**整文件覆盖**，不删头 —— 前提是备份里就有头。
3. **官方版要留档**。
   恢复时官方版另存为 `<文件>.upstream.<时间戳>`。
   这一条既是**可回退**，也是**许可证上的自证**：
   能一眼看出「哪部分是上游的、哪部分是本地的」。

### 3.3 公开仓的现状

| | 本仓（公开） | 设备上 / 设备实例仓（私有） |
|---|---|---|
| 派生的 `starts/` 文件本体 | **不在仓里** | 在（`PATCH_DIR` 与实例仓里） |
| `post-sc-update.sh`（恢复机制） | ✅ 在（**MIT**） | ✅ 同一份 |
| 声明 | [NOTICE](../NOTICE) 的「Derivative works」节 | 各自的 NOTICE |

> 公开仓**不含任何第三方源码**（[NOTICE](../NOTICE) 明写
> “This repository contains **no third-party source code**”），
> 它只提供**恢复派生件的机制**。
> 派生件本体在设备上按 GPL-3.0 存在。

### 3.4 一句话口径

> 本仓是 MIT；**被本地补丁改过的 ShellCrash `starts/` 脚本是 GPL-3.0 派生件**，
> 保留上游版权头；两者并列共存，边界是「**有没有复制上游代码**」。

---

## 4. 怎么跟着上游更新

### 4.1 文件 → 上游路径对照

| 本仓 / 设备上的对象 | 对应上游 | 上游仓库 | 本仓怎么用它 |
|---|---|---|---|
| `$CRASHDIR/start.sh` | `start.sh` | ShellCrash | `guardian.sh` §1 拉起核心；`recover-now.sh` §3 停/起；`post-sc-update.sh` §4 启动 |
| `$CRASHDIR/task/task.sh` | `task/task.sh` | ShellCrash | `guardian.sh` §5 的 `hotupdate` 子命令（重生成运行态配置） |
| `$CRASHDIR/configs/ShellCrash.cfg` | `configs/ShellCrash.cfg` | ShellCrash | `secret=` 行的真源（`guardian.sh` §运行时 现读） |
| `$CRASHDIR/starts/start_legacy_wd.sh` | `starts/start_legacy_wd.sh` | ShellCrash | legacy 看门狗；`guardian.sh` 收尾补它的 cron 行 |
| `$CRASHDIR/starts/<被补丁的>` | `starts/<同名>` | ShellCrash | **派生件**，见 §2 |
| `$CRASHDIR/CrashCore.raw` | mihomo release 二进制 | mihomo | `post-sc-update.sh` §5 的 `-t` 配置校验；**本仓不分发二进制** |
| 控制 API `/version` `/configs` `/rules` `/proxies` `/connections` `/logs` `/dns/query` | 同名路径 | mihomo | `mihomo/mihomo_api.py` 封装 |
| `/etc/rc.local` | `package/base-files/files/etc/rc.local` | openwrt/openwrt | 由 `/etc/init.d/done`（`START=95`）以 `sh /etc/rc.local` 调用；上游默认内容以 `exit 0` 收尾 |
| `/etc/init.d/dnsmasq` | `package/network/services/dnsmasq/files/dnsmasq.init` | openwrt/openwrt | 依赖 `-C /var/etc/dnsmasq.conf.*` ⇒ `/var` 目录必须在 |
| `/etc/init.d/firewall` | `package/network/config/firewall4/` | openwrt/firewall4 | `firewall restart` = 重生成 nft 规则集 |
| `/etc/crontabs/root` | busybox crond | openwrt/openwrt | `crontab $CRON_FILE` 生效方式 |
| `/var` → `tmp` 软链 | `package/base-files/Makefile` | openwrt/openwrt | `CONFIG_TARGET_ROOTFS_PERSIST_VAR` 未开时的默认行为 |
| geosite / geoip 数据 | meta-rules-dat | MetaCubeX/meta-rules-dat | **只引用来源地址**，本仓与工具都不分发 |

### 4.2 上游更新后的处理流程

```sh
# 1) 官方脚本更新完了，先看本仓的补丁还在不在
sh openwrt/post-sc-update.sh check

# 2) 报告里出现「缺标记」→ 手工把补丁重打在新版上
#    打完把新文件放进 PATCH_DIR 作为备份
#    同步更新 PATCH_SPEC 里的标记（标记变了要一起改）

# 3) 恢复 + 验收
sh openwrt/post-sc-update.sh

# 4) 顺手核一下上游的接口有没有变
#    ShellCrash: start.sh / task.sh 的子命令名、configs/ShellCrash.cfg 的键名
#    mihomo:     控制 API 的路径与返回结构（mihomo_api.py 的解析）
#    OpenWrt:    rc.local 的调用方式、init 脚本的 start/stop 语义
```

**顺序不要反**：先确认上游改了接口，再改本仓；
先重打补丁，再跑恢复 —— 直接跑恢复会把官方版盖回去。

### 4.3 核对上游原文

```sh
# OpenWrt 的某个文件（把 tag 换成对应固件版本）
curl -sL https://raw.githubusercontent.com/openwrt/openwrt/v25.12.6/package/base-files/files/etc/init.d/done

# mihomo 的控制 API 文档在仓库的 docs/ 下
curl -sL https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/docs/config.yaml

# ShellCrash 的脚本
curl -sL https://raw.githubusercontent.com/juewuy/ShellCrash/master/starts/start_legacy_wd.sh
```

### 4.4 哪些上游变化**不用**动本仓

| 上游变化 | 要不要动本仓 |
|---|---|
| ShellCrash 改了订阅模板的格式 | ❌ 本仓不解析订阅 |
| mihomo 加了新规则类型 | ⚠️ `rule_audit.py` 的类型分表要加一行（否则新类型进不了 `type_counts`） |
| mihomo 改了控制 API 的返回结构 | ✅ `mihomo/mihomo_api.py` 的解析要改 |
| OpenWrt 改了 `rc.local` 的调用方式 | ✅ `openwrt/rc.local` 的硬约束要改 |
| meta-rules-dat 出了新数据集 | ✅ 规则源要更新（**但本仓不存数据集**） |
| 上游改了 LICENSE | ✅ [NOTICE](../NOTICE) 与 §1 的表要改 |

---

## 5. 数据源：meta-rules-dat

`RULE-SET,cn` 这类规则集的内容来自 **MetaCubeX meta-rules-dat**。

- 本仓**不分发**任何 geosite / geoip 数据；
- 工具只在需要时**按 URL 引用**（比如用文本 geosite 列表模拟 `RULE-SET,cn`），
  数据文件由使用者自己取；
- ⚠️ **模拟不等于运行态** ——
  运行态用的是编译好的 `cn.mrs`，可能比文本列表滞后。
  这条坑见 [PITFALLS.md](PITFALLS.md) 的 P14。

---

## 6. 相关文档

- [ARCHITECTURE.md](ARCHITECTURE.md) —— 本仓自己的结构与「会改什么」。
- [MAINTENANCE.md](MAINTENANCE.md) —— 改了脚本要回归哪几条。
- [PITFALLS.md](PITFALLS.md) —— 踩过的坑。
- [SECRETS.md](SECRETS.md) —— 凭据位置索引。
- 仓库根 [NOTICE](../NOTICE) —— 第三方声明与派生件记录的**正本**。
