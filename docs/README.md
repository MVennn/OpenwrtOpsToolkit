# docs/ 索引

> **一句话**：这里只有索引与定位，不放正文 —— 每篇文档一句话说明「它管什么」，
> 规则本身按 [DOC-RULES.md](DOC-RULES.md) 的单一正本原则只在对应文档里定义。

文档分四类。每篇开头都有一个「一句话」引言块，先看它再决定要不要往下读。
带 **（正本）** 标记的文档是该主题的**唯一权威定义处**；别处只留一句话概述 + 指向它的链接。

---

## 一、架构与机制

| 文档 | 一句话定位 |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | 三个域各解决什么问题、**会改设备哪些状态**、配置怎么读、诊断链路怎么走 |

## 二、工具专项

| 文档 | 一句话定位 |
|---|---|
| [PITFALLS.md](PITFALLS.md) | 踩坑总汇（**正本**）：每条写清「为什么错」与「下次怎么避」 |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | 排错手册（**正本**）：按「现象 → 排查步骤 → 原因 / 解法」组织，标题即检索词 |

## 三、流程与规范

| 文档 | 一句话定位 |
|---|---|
| [DOC-RULES.md](DOC-RULES.md) | 文档规则（**正本**）：分类定位、单一正本映射表、链接纪律、变更触发矩阵、孤儿零容忍 |
| [VERSIONING.md](VERSIONING.md) | 版本晋升规则（**正本**）：三段式进位、版本号只在 CHANGELOG 标题维护、什么时候不动版本号 |
| [MAINTENANCE.md](MAINTENANCE.md) | 维护流程（**正本**）：配置模板怎么升级、诊断结果保留策略、脚本改动的回归清单 |
| [SECRETS.md](SECRETS.md) | 凭据与设备标识位置（**正本**，只写位置不写值）：本仓存什么、不存什么、真值在哪 |
| [UPSTREAM.md](UPSTREAM.md) | 上游关系：ShellCrash / mihomo / OpenWrt 的版本与派生边界、哪些文件是打补丁派生件 |

## 四、参考资料

| 位置 | 一句话定位 |
|---|---|
| 仓库根 [README.md](../README.md) | 门面：这是什么、适用环境、快速开始、目录结构、文件清单、已知坑 |
| 仓库根 [AGENTS.md](../AGENTS.md) | 机器协议：PROGRESS 归属、设备值外置、CodeGraph |
| 仓库根 [CHANGELOG.md](../CHANGELOG.md) | 开发者记录；**版本号本身**在这里维护，**进位规则**见 [VERSIONING.md](VERSIONING.md) |
| 仓库根 [PROGRESS.md](../PROGRESS.md) | 本仓唯一进度台账（追加式批次日志） |
| 仓库根 [NOTICE](../NOTICE) | 第三方声明：ShellCrash（GPL-3.0）、mihomo（MIT）、OpenWrt（GPL-2.0） |
| 仓库根 [LICENSE](../LICENSE) | 许可证全文（**MIT**） |
| [release-notes/](release-notes/README.md) | 面向使用者的 Release 说明，文件名 = 版本号；格式规范在它的 README。已发布：[v0.1.0.md](release-notes/v0.1.0.md) |
| `../memories/` | 记忆文档：踩过的坑与实测结论（索引见 `../memories/MEMORY.md`） |

---

> 新增 / 删除文档后**必须同步更新本索引**（规则见 [DOC-RULES.md](DOC-RULES.md) §7）；
> 新文档至少要被一处既有文档引用，不允许孤儿。
