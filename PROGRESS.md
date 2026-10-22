# PROGRESS — Openwrt 运维工具箱

> **一句话**：本仓**唯一**的进度台账（追加式批次日志）。
> 规则正本见 [docs/DOC-RULES.md](docs/DOC-RULES.md) 与 [docs/MAINTENANCE.md](docs/MAINTENANCE.md)。

---

## 目标

把散落在私有工作目录里的 **OpenWrt 设备侧运维脚本** 与 **mihomo 诊断工具** 抽成一个
**任何人拿去就能用**的公开仓：设备相关的值全部外置到配置，脚本逻辑一个字节不改。

## 步骤

- [x] 定风格契约与目录分工（`openwrt/` 设备侧 / `mihomo/` 控制面 / `cdn/` 站点侧）
- [x] 建仓骨架、落 logo、写顶层文档（README / AGENTS / CHANGELOG / NOTICE / SECURITY / CI）
- [x] `mihomo/` 与 `cdn/` 的工具迁入并通用化
- [x] `openwrt/` 的脚本迁入并通用化（节点名 / 策略组名 / nft 路径外置到 `device.conf`）
- [x] 补 `docs/` 全套（架构 / 踩坑 / 排错 / 维护 / 凭据位置 / 上游边界）
- [x] 文档自检脚本 `tools/check-docs.py` 上线
- [x] 记忆文档从两个私有仓归拢过来
- [ ] 真机验证 —— 在**另一台**设备上按 README 的「快速开始」完整跑一遍（当前只在原设备验证过）
- [ ] 补 `docs/RELEASE.md`（发版流程尚未成篇）

## 核心结论

| # | 结论 | 依据 |
|---|---|---|
| 1 | **私有性来自配置与证据，不来自代码** | 两个私有仓的脚本几乎全是设备无关的：节点名/策略组名是唯一的耦合点 |
| 2 | 耦合点可以**一次性外置** | 读取顺序「环境变量 → `device.conf` → 占位符默认值」，三种用法都覆盖 |
| 3 | 源仓与本仓的关系是**实例 vs 通用版** | 源仓那份是**已部署到路由器**的设备实例，本仓是通用版；两者会分叉，差异记录在各源仓的 `docs/UPSTREAM.md` |

## 待解决的问题

- 待验证：`guardian.sh` 的通用版在**没有那台设备的策略组名**时行为是否正确
  （占位符默认值会导致"找不到组"而跳过自愈 —— 这是期望行为，但要确认不会误判为"配置坏了"）。
- 待验证：`cdn/` 下的域名清单是针对腾讯系的，其他站点需要自己加 —— 是否有更通用的抽象方式。
- 待定：源仓与本仓的**同步机制**（目前是手工对拍，没有自动化）。

## 状态：进行中（建仓完成，真机验证待做）
# 2026-10-21 README 收敛

## 已完成变更
- [x] 重写根 `README.md`（logo 头 + 徽章 + 用户门面，无「一句话」块）
- [x] 目录结构 / 文件清单迁入 `docs/TOOLS.md`，DOC-RULES / docs/README 引用同步
- [x] `tools/check-docs.py` 豁免根 README 的引言块检查
- [x] CHANGELOG 增补「README 收敛批次」

## 自检
- check-docs ✓（19 篇）；ast.parse ✓；`sh -n openwrt/*.sh` ✓；`openwrt/conf/device.conf` 不存在 ✓

## 状态: 已完成

---

# 2026-10-21 README 门面统一（对齐 GSAuxiliary 七节）

## 背景
- 在「README 收敛批次」之后再收一轮：门面向读者是使用者，开发者内容下沉 `docs/`；
  门面资源统一由 `assets/icon.svg` 渲染。

## 已完成变更
- [x] 根 `README.md` 收敛为七节门面（90 行）：这是什么 / 环境要求 / 使用 / 反馈 / 免责声明 / 开源鸣谢 / 许可证
- [x] 三个域速查表与「设计原则」下沉 `docs/ARCHITECTURE.md` §1 / §1.1
- [x] 新增 `tools/make_social_preview.py`（自带 SVG 渲染器，无第三方依赖），生成
      `assets/logo.png` 与 `assets/social-preview.png`
- [x] `docs/DOC-RULES.md` 正本映射表、`docs/MAINTENANCE.md` §3.8、`docs/README.md` 索引同步
- [x] `tools/github-setup.py` 补 ZCodeTpsBadge / GSAuxiliary，描述改成面向使用者的口径
- [x] CHANGELOG 增补「门面统一批次」

## 自检
- `python tools/check-docs.py` ✓（19 篇）
- GitHub 侧：8 个仓的描述与话题已写入；5 个公开仓的社交预览图已上传并与仓内资产逐字节一致

## 状态: 已完成

---


# 2026-10-22 大流量守卫（bulk-guard.sh）

## 背景
- 公共备用节点只做「机场全挂」的兜底，不承载大流量；想让已知的大文件下载
  走公共池省机场流量，跑不满时自动切回机场。
- 先验证了 mihomo 原生做不到：`url-test` / `fallback` 只测首包
  （`/proxies/<节点>/delay` 请求 3MB 只花 233ms，正文没传）。

## 已完成变更
- [x] 新增 `openwrt/bulk-guard.sh`（配置驱动：`BULK_GROUP` / `BULK_PUBLIC` / `BULK_AIRPORT`）
- [x] 活跃连接爬速判定：`/connections` 累计字节采样，连续 2×30s 低于 200 KB/s 才切；
      0 字节窗口跳过（暂停 / 已传完）
- [x] `openwrt/conf/device.conf.example` 补 `BULK_*` 配置项
- [x] `openwrt/README.md`：四个脚本 → 五个，补部署 cron 与保守设计说明
- [x] `docs/TOOLS.md`：目录树 + 会改设备状态表
- [x] CHANGELOG 增补「大流量守卫批次」

## 真机验证（AX3000T）
- [x] 探测文件大小校准：同一公共节点 2MB 1.19 / 4MB 1.65 / 8MB 2.07 / 20MB 2.67 MB/s
      → 选 4MB + 阈值 800 KB/s（≈ 持续 10 Mbps）
- [x] 链路验证：`proof.ovh.net` → `📺 大流量` → `🆓 公共备用` → 公共节点（`/connections` 的 chains 实测）
- [x] 探测源换过一次：Cloudflare `__down` 在公共节点上被限流成 403（403 的「速度」会误判成节点慢），
      改用 OVH 测速文件 + `Range: 0-3999999`；探测函数校验 `200/206` 与字节数，无效时返回 -1、不切组
- [x] 状态机验证：公共池低于阈值 → 切机场 + 冷却；冷却结束且空闲 → 切回公共池 + 首测
- [x] cron `*/10 * * * *` 已挂；组名从 `/etc/openwrt-ops/device.conf` 读取

## 自检
- `sh -n openwrt/bulk-guard.sh` ✓

## 状态: 已完成

---

# 2026-10-22 仓库门面：Issue 表单

## 目标
对齐 GSAuxiliary 的仓库门面：补上 Issue 表单，让反馈自带设备、版本、完整命令与输出。

## 已完成变更
- [x] 新增 `.github/ISSUE_TEMPLATE/bug_report.yml` —— 设备与固件、mihomo / ShellCrash 版本、
      脚本与完整命令、输出原文、脱敏确认
- [x] 新增 `.github/ISSUE_TEMPLATE/feature_request.yml` —— 场景、期望效果、范围确认
- [x] 新增 `.github/ISSUE_TEMPLATE/config.yml` —— 关掉空白 Issue，挂排错手册与工具清单

## 自检
- `python tools/check-docs.py` ✓，退出码 0
- 三份 YAML 均可被 `yaml.safe_load` 解析

## 状态: 已完成

---

# 2026-10-22 收尾大扫除

## 目标
按 GoldSunEnhance 的《大扫除作业书》做减法与漂移对齐：清可再生产物、
把文档里的脚本计数与键表对齐到实际脚本、补 Release 说明的反馈入口规则。

## 已完成变更
- [x] L1：删 `cdn/` `mihomo/` `tools/` 下的 `__pycache__/`（`py_compile` 生成的缓存，`.gitignore` 已覆盖）
- [x] L3：设备侧脚本计数四 → 五（`openwrt/README.md`、`docs/ARCHITECTURE.md`、`docs/UPSTREAM.md`、
      `docs/MAINTENANCE.md`）；`openwrt/README.md` 删掉重复的设计原则块
- [x] L3：`docs/ARCHITECTURE.md` §3.5 键表 / §4.1 矩阵补 `bulk-guard.sh` 与 `BULK_*`，
      新增 §4.6 行为说明；§5.4 切组脚本改为 `guardian.sh` / `bulk-guard.sh`
- [x] L3：`docs/TOOLS.md` 目录树补 `tools/make_social_preview.py`，根目录名改为实际仓名
- [x] L3：`docs/release-notes/README.md` 补「反馈入口」规则（第二行、绝对地址、已发布正文不回填）；
      修掉「尚未上传远端，也未 git init」的过期说法
- [x] L4：`docs/MAINTENANCE.md` 补 `BULK_*` 默认值分类、大流量守卫日志 / 状态保留行、
      §3.8 回归清单、§7 维护记录
- [x] 记账：CHANGELOG 增「收尾大扫除」段

## 自检
- `python tools/check-docs.py` ✓（19 篇，退出码 0）
- 全部 `.sh` 过 `bash -n` ✓；全部 `.py` 过 `python -m py_compile` ✓
- 删 `__pycache__`（约 208 KB）后仓体积 1.5M（开工 1.4M；净增来自本轮文档修改）

## 状态: 已完成

---

# 2026-10-22 大流量守卫按吞吐轮换

## 背景
Telegram 走「大流量 → 公共备用」时实测只有 ~85 KB/s，而同一时刻机场池 3.56 MB/s
（差约 42 倍）。旧守卫有两处盲区：探测 40 秒超时且不足 90% 会被判「无效」，
活跃连接按组内总和采样会被 Telegram 的连接重连拉成负数 —— 两者都让「慢」判不出来。

## 已完成变更
- [x] 重写判定：按 connection id 求正增量、探测超时算慢、0 字节窗口区分停滞/暂停
- [x] 公共池内按吞吐缓存轮换（每会话最多 2 个活节点），都不行再切机场
- [x] 机场停留 + 空闲回切，并钉住缓存最优节点；钉住节点每轮做健康检查
- [x] 实例锁；cron 从 `*/10` 改为 `*/3`
- [x] 配置样例 / ARCHITECTURE / TOOLS / README / MAINTENANCE 同步
- [x] 真机验证：钉住的「公共-05」死亡后 26 秒自愈到「公共-06」；
      100MB 下载下 dry-run 测到 1335 KB/s，跳过 7 个死节点后给出改试「公共-09」

## 自检
- `sh -n openwrt/bulk-guard.sh` ✓
- 路由器实跑 `--status` / `--dry-run` ✓，日志与缓存写入符合预期
- `python tools/check-docs.py` ✓
- 路由器 cron 已改为 `*/3`，脚本哈希与仓内一致

## 状态: 已完成

---
