# 文档规则

> **一句话**：docs/ 下的文档怎么分类、怎么互相引用、改动时连带改哪些 ——
> 本篇只管「怎么写、怎么保持一致」，不承载任何具体技术规则。

---

## 1. 分类与定位

docs/ 分四类（索引见 [README.md](README.md)）：

| 类别 | 收什么 | 现有成员 |
|---|---|---|
| 架构与逆向 | 三个域各解决什么、脚本会改设备什么、配置怎么读 | ARCHITECTURE、UPSTREAM |
| 功能专项 | 一个主题一篇 | PITFALLS、TROUBLESHOOTING |
| 流程与规范 | 构建、发版、版本、维护、排错、命名、编码纪律、文档规则 | VERSIONING、MAINTENANCE、SECRETS、DOC-RULES、release-notes/ |
| 参考资料 | Release 说明、记忆文档、仓库根文档 | release-notes/、memories/、CHANGELOG、NOTICE、LICENSE |

每篇文档开头必须有一个 **「一句话」引言块**（`> **一句话**：…`），
让读者不用往下翻就知道这篇管什么。新文档没有它不算写完。

**例外**：`evidence/` 下的**原始证据**与**归档报告**（`docs/archive/`）是**只读原始数据**，
不为它们补引言块 —— 补了就改动了原始记录。它们的定位由本索引承担。

---

## 2. 单一正本原则

**每条规则只在一篇文档里定义；其余位置只允许一句话概述 + 指向正本的链接。**
两处都写全文，迟早各改各的。

权威正本映射表：

| 规则 | 正本 |
|---|---|
| 三个域的边界、脚本会改设备什么、配置怎么读 | [ARCHITECTURE.md](ARCHITECTURE.md) |
| 设备配置怎么填、脚本怎么装 | [../openwrt/README.md](../openwrt/README.md) |
| 上游项目与派生件的许可边界 | [UPSTREAM.md](UPSTREAM.md) |
| 保留策略与清理流程（备份区命名 / 修剪阈值 / 改完即删） | [MAINTENANCE.md](MAINTENANCE.md) |
| 排障步骤 | [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
| 凭据存放位置与轮换建议 | [SECRETS.md](SECRETS.md) |
| Release 说明格式（动词 / 一行一条 / 覆盖率红线 / 固定尾巴） | [release-notes/README.md](release-notes/README.md) |
| 文件清单（本地路径 → 路由器目标路径 → 被谁调用 → 回退方式） | 仓库根 [README.md](../README.md) 的「文件清单表」 |
| 变更台账（按对象拆行） | 仓库根 [CHANGELOG.md](../CHANGELOG.md) |
| **版本晋升规则**（三段式进位 / 有没有功能更新怎么判） | [VERSIONING.md](VERSIONING.md) §1–§2 |
| **交付 / 发版规则**（版本号在哪维护 / 什么时候不动版本号 / 打 tag） | [VERSIONING.md](VERSIONING.md) §3、§5 + [release-notes/README.md](release-notes/README.md) |
| 许可证 | 仓库根 [LICENSE](../LICENSE)（MIT 全文） |
| 文档本身的写法规则 | [DOC-RULES.md](DOC-RULES.md)（本篇） |
| 代理的工作约定（PROGRESS 归属 / 子代理分片） | 仓库根 [AGENTS.md](../AGENTS.md) |

### 禁止重复清单（勿重蹈）

1. **架构说明 ↔ 各目录 README**：`ARCHITECTURE.md` 讲**整体**（三个域的边界、
   配置怎么读），`openwrt/README.md` 讲**单个目录**怎么用。
   两者都出现过的结论：架构说明写**当前结构**，各目录 README 写**过程与原因**；
   结构变了就改架构说明，**不改各目录 README 正文** —— 报告尾部挂勘误节。
2. **设备配置 ↔ 脚本默认值**：设备相关的值写在
   [../openwrt/conf/device.conf.example](../openwrt/conf/device.conf.example)（带说明）；
   脚本里只写**占位符默认值**，不复述真实值。
3. **排障步骤 ↔ 已知坑**：现象 → 步骤 → 解法的**完整流程**只写在
   [TROUBLESHOOTING.md](TROUBLESHOOTING.md)；机制与红线只写在
   [PITFALLS.md](PITFALLS.md)，两边互链不复述。
4. **凭据明文 ↔ 任何其它文档**：明文值只出现在「它本来就在那儿」的地方
   （历史文档、证据采集）；[SECRETS.md](SECRETS.md) 只写**位置**，不抄值。
5. **CHANGELOG ↔ Release 说明**：CHANGELOG 是**开发者记录**（症状 / 根因 / 改法）；
   Release 说明是**给使用者看的清单**。两者受众不同，不能一份两用。
6. **VERSIONING ↔ CHANGELOG 头部**：版本**号本身**（当前是哪个版本）只在
   [CHANGELOG.md](../CHANGELOG.md) 的版本标题里；**进位规则**只在
   [VERSIONING.md](VERSIONING.md) §1–§2。两处都写规则，迟早各改各的。

---

## 3. 红线内容保护

以下内容在文档合并、压缩、改写时**必须逐字保留，一个不删**：

1. **路径与接口名** —— 路由器上的目标路径（`/etc/ShellCrash/guardian.sh`、
   `/etc/rc.local`、nft 表名 `inet quicguard` / `inet mixedport`…）、
   端口（`7890` / `7892` / `9999` / `1053`）、cron 行、配置键名。
   这些是**事实**，不是描述；写错一个字符，脚本就找不到东西。
2. **实测数字与它们的时点** —— 内存 / 闪存占用、出口 IP 与 `cc` 判定、
   节点延迟、规则条数。
   **数字后面必须带时点**（「2026-10-20 15:00 审计时」），
   因为同一项在不同时点是不同的值（overlay 40% → 65% 就是同一天的事）。
3. **脚本的 shebang 位置与调用方式** —— `guardian/guardian.sh` 的 `#!/bin/sh`
   在**第 9 行**，直接 `./guardian.sh` 不会执行，只能 `sh` / `/bin/ash` 调用。
   这是脚本的**现状**，不是笔误，别顺手「修正」。
4. **凭据的明文位置** —— 见 [SECRETS.md](SECRETS.md)；
   文档里**不写值**，但**位置清单必须完整**，漏一条就等于没防。

---

## 4. 链接纪律

- 统一用**相对链接 + 锚点**（形如 `[标题](文档名.md#锚点)`，写时用半角括号），不用绝对路径。
- **锚点必须真实存在** —— 指向的标题、文件名、章节号都得在那儿。
- **改动 / 删除 / 合并文档后必须双向点验**：
  - 出链：新文档里指向别处的链接目标还存在、锚点没变；
  - 入链：全仓搜旧文件名（Grep），把指向它的链接改成新位置 ——
    **禁止只删文档不改引用方**。
- 判断某段「重复」是否该收敛时，先看它被谁引用；收敛后引用方必须同步改。
- 历史记录里的旧文件名（如 CHANGELOG 历史段落里提到的 `F:\Project\Openwrt\...`
  旧路径）可保留原样 —— 那是当时的事实；
  但**正文中指向现役文档的链接**必须始终指向现役文档。
- **待补文档**（映射表里标「待补」的）暂时**不写成链接**，
  用反引号写成代码 + 一句「待补」说明 —— 不留死链。

---

## 5. 变更触发矩阵

改了什么，就必须连带改什么：

| 变更 | 必须同步 |
|---|---|
| 改脚本（`openwrt/` `mihomo/` `cdn/`） | [TOOLS.md](TOOLS.md) 的工具表、[ARCHITECTURE.md](ARCHITECTURE.md) 的「会改什么」、[TROUBLESHOOTING.md](TROUBLESHOOTING.md) 的对应节 |
| 新增/改了一个环境变量 | [../openwrt/conf/device.conf.example](../openwrt/conf/device.conf.example)、[SECRETS.md](SECRETS.md) 的变量表 |
| 脚本报错文案或用法变了 | [PITFALLS.md](PITFALLS.md)、[TROUBLESHOOTING.md](TROUBLESHOOTING.md) 的对应节 |
| 新增 / 删除 / 改名文件 | 仓库根 [README.md](../README.md) 的目录结构与文件清单表 |
| 新增 / 删除 / 改名文档 | [README.md](README.md) 索引（见 §7） |
| 改了保留策略 / 清理规则 | [MAINTENANCE.md](MAINTENANCE.md) |
| 改了凭据的存放位置或新增了凭据 | [SECRETS.md](SECRETS.md)（位置清单）；`.gitignore` 的排除项 |
| 改了版本晋升 / 发版规则 | [VERSIONING.md](VERSIONING.md)；仓库根 [CHANGELOG.md](../CHANGELOG.md)（版本号本身） |
| 改了许可证 | 仓库根 [LICENSE](../LICENSE)、[NOTICE](../NOTICE)、[README.md](../README.md) 的许可证段 |
| 发版 | 仓库根 [CHANGELOG.md](../CHANGELOG.md)、[docs/release-notes/](release-notes/) 下对应版本说明（格式正本：[release-notes/README.md](release-notes/README.md)；版本号进位规则：[VERSIONING.md](VERSIONING.md)） |
| 内部重构 / 底层修复 / 死代码 | CHANGELOG 与 Release 说明里**必须按对象单列一行**（算「修复」，不许打包成「代码整理」） |

---

## 6. 体量预算与样例时效

- **单篇 ≤ 800 行。** 超了就按「正文档 + 踩坑史」拆：正文档留结论与约束，
  历史 / 根因分析移到 HISTORY 篇；一次性报告直接进 `docs/archive/`。
- **样例时效**：带日期标注的样例（如「2026-10-20 实测」）可容忍过时 ——
  它们是历史记录；但**当前值类内容**（overlay 占用率、当前出口、当前策略组）
  必须随实际变化同步，不允许停留在旧状态。
- **阶段性报告不改写**：这类报告是「当时发生了什么」的定稿，
  结论过时了就在**文末追加勘误节**（`## 勘误（日期 复核）`），不动正文。

---

## 7. 索引维护与孤儿零容忍

- [README.md](README.md) 是 docs/ 的**唯一索引**，**新增 / 删除 / 改名文档必须同步更新**。
- **孤儿文档零容忍**：任何新文档必须至少被一处既有文档引用（或进索引并有明确入口），
  否则等于没写。
- 仓库根的 [README.md](../README.md) 与 [docs/README.md](README.md) 是**两个层级**：
  前者是门面（这是什么 / 怎么用），后者是 docs 内部的索引（每篇一句话定位）。
  **两者都不承载正文规则。**
