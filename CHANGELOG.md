# 更新日志

> **一句话**：本仓的开发者记录 —— 每个版本改了什么、为什么、怎么验。
> 顶部的版本命名规则是**摘要**，**正本见 [docs/VERSIONING.md](docs/VERSIONING.md)**。

版本号形如 `vX.Y.Z`。**有功能更新进次版本（+0.1.0，补丁归零）；没有功能更新进补丁版本（+0.0.1）。**

---

## [未发布] — 2026-10-21

> 本仓刚从一个私有工作目录里拆出来，首版建仓。

### 新增

- 新增 `openwrt/` —— 设备侧运维脚本：`guardian.sh`（网络守护）`recover-now.sh`（离线恢复）
  `rc.local`（开机自启模板）`post-sc-update.sh`（ShellCrash 补丁恢复）+ `conf/device.conf.example`。
- 新增 `mihomo/` —— 控制面诊断工具：`mihomo_api.py`（客户端库）`rule_audit.py`（规则审计器）
  `scan_rules.py` `mihomo_log.py` `capture_live.py` `latency_probe.py`。
- 新增 `cdn/` —— 站点可达性专项：`qq_cdn_probe.py` `qq_dns_path.py` `qq_domain_classify.py`
  `qq_rule_probe.py` `quic_probe.py`。
- 新增 `tools/check-docs.py` —— 文档自检（链接 / 锚点 / 一句话引言块 / 孤儿文档），CI 里跑的就是它。

### 调整

- 调整 设备相关的值 —— 节点名、策略组名、nft 表路径、健康检查目录全部从源码里外置到
  `openwrt/conf/device.conf`（读取顺序：环境变量 → 配置文件 → 占位符默认值）。
- 调整 凭据 —— mihomo 控制 API secret 改走 `MIHOMO_SECRET` 环境变量，仓内零明文。
- 调整 文档 —— 补 `docs/ARCHITECTURE.md`（会改什么 / 配置怎么读 / 诊断链路）、
  `docs/PITFALLS.md`（踩坑总汇）、`docs/TROUBLESHOOTING.md`（排错手册）、
  `docs/MAINTENANCE.md`（维护流程）、`docs/SECRETS.md`（凭据位置索引）、`docs/UPSTREAM.md`（上游与派生边界）。

### 待补

- 待补 `docs/RELEASE.md` —— 发版规则（交付流程、打 tag、发 Release 说明的步骤）尚未成篇；
  目前的发版约定散在 `docs/VERSIONING.md` 与 `docs/release-notes/README.md` 里。
- 待补 截图 —— README 还没有界面截图（`openwrt/` 是脚本集，没有界面）。

### README 收敛批次（2026-10-21）

参照系列仓 gsauxiliary 的门面格式，把根 `README.md` 收敛为**面向用户**的说明：

- 调整 文档 —— 根 README 重写为 logo 头 + 徽章 + 这是什么 / 适用环境 / 使用 / 反馈 / 免责声明 / 开源鸣谢 / 许可证；顶部不写「一句话」引言块（对齐 gsauxiliary 门面）
- 调整 文档 —— 「目录结构」「文件清单」迁入 [docs/TOOLS.md](docs/TOOLS.md)（工具清单正本）；「已知坑」统一看 docs/PITFALLS.md
- 调整 文档 —— DOC-RULES / docs/README 里指向根 README「文件清单 / 已知坑」的引用同步改指新位置
- 调整 工具 —— `tools/check-docs.py` 豁免根 README 的「一句话」引言块检查
