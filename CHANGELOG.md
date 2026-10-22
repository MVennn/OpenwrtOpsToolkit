# 更新日志

> **一句话**：本仓的开发者记录 —— 每个版本改了什么、为什么、怎么验。
> 顶部的版本命名规则是**摘要**，**正本见 [docs/VERSIONING.md](docs/VERSIONING.md)**。

版本号形如 `vX.Y.Z`。**有功能更新进次版本（+0.1.0，补丁归零）；没有功能更新进补丁版本（+0.0.1）。**

---

## [未发布] — 2026-10-21 ~ 2026-10-23

### 守卫与探测（2026-10-23）

- 修复 `openwrt/guardian.sh` —— 3.5 / 3.6 的耗时计算多除了 2（取 max 后又除），
  劣化阈值被压低一半；改为取 max
- 修复 `openwrt/guardian.sh` —— 回退自愈的组名检查用 `grep` 正则，组名含
  `[` / `*` / `.` 时误判「组缺失」并触发 hotupdate；改 `grep -F`
- 修复 `openwrt/bulk-guard.sh` —— `state_set` 用 `|` 作 sed 分隔符，值里带 `|`
  时 sed 报错被 `2>/dev/null` 吞掉、旧值残留（冷却 / 空闲计时会卡住）；
  改为写临时文件后原子替换
- 修复 `cdn/qq_cdn_probe.py` —— DNS 查询把整个域名编成单个含点号的标签
  （wire format 非法），所有域名都回 NXDOMAIN，`dns` 与 `probe` 两段输出全假；
  改为逐标签编码。同文件还有两处：`data[i] & 0xC0 == 0xC0` 的运算符优先级错误
  （实际只在判断最低位）、单次 `recv(200)` 取不满 HTTP 状态行 —— 后者改为
  循环读到 `

`
- 修复 `mihomo/rule_audit.py` —— `findings.json` 硬编码写到当前工作目录，
  从仓根跑会写脏工作区；改为跟 `REPORT` 同目录
- 修复 `openwrt/recover-now.sh` —— check 模式不再改写 `fake_ip_filter`
- 调整 `tools/check-secrets.py` —— `SKIP_DIRS` 去掉 `cdn` / `mihomo`
  （11 个跟踪文件此前完全不在扫描范围）
- 验证 —— `sh -n` ✓、全部 `.py` `ast.parse` ✓、`check-docs.py` ✓（19 篇）、
  `check-secrets.py` ✓（56 个文件，比改动前多 11 个）；`qq_cdn_probe.py dns` 实测
  `qpic.cn` 与 `thirdwx.qlogo.cn` 解析出真实 IP；`state_set` 用 `a|b&c#d`
  验证写读一致


### 文档骨架对齐系列仓（2026-10-23）

- 调整 `docs/release-notes/` —— 文件名去掉 `v` 前缀（`v0.1.0.md` → `0.1.0.md`）；
  `v` 前缀只属于发版 tag，tag 未动。
- 调整 `docs/README.md` —— 索引引言块与结尾提醒措辞对齐基准仓，一句话定位压到一行读完；
  `UPSTREAM.md` 归入「架构与机制」，补 `openwrt/README.md` / `CONTRIBUTING.md` / `SECURITY.md` 条目。
- 调整 `docs/VERSIONING.md` —— §5 改为「不发版的时候：不要动版本号」，按手工发布号改写；
  §2 判断口诀改为「使用者拿到的『能做什么』有没有变」，边界表补「改脚本调用方式」一行。
- 调整 `docs/DOC-RULES.md` —— §1 补「文件命名：全大写 + 连字符」（`git mv` + 全仓 grep 纪律）；
  变更触发矩阵补破坏性变更与改名两行。

### 大流量守卫按吞吐轮换（2026-10-22）

- 重写 `openwrt/bulk-guard.sh` 的判定与恢复链路：
  - 活跃连接改为按 connection id 求**正增量之和**，连接关闭不再把总和拉低
    （Telegram 多连接重连会被旧逻辑误判成暂停）；第一个窗口慢、第二个 0 字节
    按停滞处理，两个窗口都 0 才按暂停放过
  - 探测跑满 40 秒超时但收到数据时按实测速率算慢，不再记「探测无效」——
    实测 84.8 KB/s 的公共节点正好卡在这条路径上，老版本永远判不出来
  - 确认为慢后先在公共池内按吞吐缓存改试，每会话最多 `BULK_MAX_TRY`（默认 2）个
    活节点，再切机场；候选切换后给 `BULK_SETTLE_SEC` 重连，再采样真实速率
  - 机场停留 `BULK_RETURN_COOLDOWN` 秒且空闲 `BULK_IDLE_SWITCH` 秒后回切公共池，
    并钉住缓存里吞吐最好的节点
  - 新增钉住节点健康检查：公共池被钉住后 URLTest 不再自动切换，每轮先确认它活着
  - 新增实例锁（3 分钟 cron 下整轮可能压边）
- 调整 部署 —— cron 从 `*/10` 改为 `*/3`
- 调整 配置样例 —— 补 `BULK_MAX_TRY` / `BULK_SPEED_TTL` / `BULK_SETTLE_SEC` /
  `BULK_IDLE_SWITCH` / `BULK_RETURN_COOLDOWN` / `BULK_PROBE_MIN_BYTES` /
  `BULK_SPEED_STATE` / `BULK_TRIED` / `BULK_LOCK`
- 调整 文档 —— `docs/ARCHITECTURE.md` §3.5 键表、§4.1 矩阵、§4.6 行为说明；
  `docs/TOOLS.md` 工具表；`openwrt/README.md` 取舍说明；
  `docs/MAINTENANCE.md` 阈值分类、保留策略、§3.8 回归项

### 收尾大扫除（2026-10-22）

- 清理 工作区 —— 删 `__pycache__/`（`py_compile` 回归时生成的缓存，`.gitignore` 已覆盖）；
  仓内无日志 / 备份 / 临时产物，`.work/` 为空（0 字节）
- 调整 文档 —— 设备侧脚本计数四 → 五（`openwrt/README.md`、`docs/ARCHITECTURE.md`、
  `docs/UPSTREAM.md`、`docs/MAINTENANCE.md`）；`openwrt/README.md` 删掉重复的设计原则块
- 调整 文档 —— `docs/ARCHITECTURE.md` §3.5 键表与 §4.1 矩阵补 `bulk-guard.sh` 列与
  `BULK_*` 键，新增 §4.6 行为说明；§5.4 注明切组脚本有两个
- 调整 文档 —— `docs/TOOLS.md` 目录树补 `tools/make_social_preview.py`，根目录名改为实际仓名
- 调整 文档 —— `docs/release-notes/README.md` 补「反馈入口」规则（第二行、绝对地址
  `.../issues/new/choose`、已发布正文不回填），并修掉「尚未上传远端，也未 git init」的过期说法
- 调整 文档 —— `docs/MAINTENANCE.md` 补 `BULK_*` 默认值分类、大流量守卫日志 / 状态保留行、
  §3.8 回归清单与 §7 维护记录
- 体积 —— 开工 1.4M → 收尾 1.5M（中途 `py_compile` 生成的约 208 KB `__pycache__` 已删；
  净增来自本轮文档修改）；`git ls-files` 合计约 512 KB

### Issue 表单（2026-10-22）

- 新增 `.github/ISSUE_TEMPLATE/` —— 问题反馈（Bug）与功能建议两套表单，外加 `config.yml`：
  Bug 表单要求填设备与固件、mihomo / ShellCrash 版本、脚本与完整命令、输出原文，
  并确认已备份、先跑过 `--dry-run` / `--check`；功能建议要求先写场景并确认「只读优先、最小化修复」

### 大流量守卫批次（2026-10-22）

- 新增 工具 —— `openwrt/bulk-guard.sh`：大流量策略组的带宽守卫。mihomo 的
  `url-test` / `fallback` 只测首包（实测 3MB 文件的 `/delay` 只花 233ms，正文没传），
  无法表达「跑不满」，所以由脚本按真实下载速率判定：组空闲时每 2 小时探测一次
  （4MB，阈值 800 KB/s ≈ 持续 10 Mbps），低于阈值切回机场并冷却 1 小时；
  有活跃连接时用 `/connections` 的累计字节采样，连续两个 30s 窗口低于
  200 KB/s 才切（0 字节窗口跳过，避免把暂停/已传完误判成卡死）
- 调整 文档 —— `openwrt/README.md`：脚本从四个变五个，补部署 cron 与
  「为什么不用 url-test / 探测文件为什么是 4MB」的说明
- 调整 配置样例 —— `openwrt/conf/device.conf.example` 补 `BULK_GROUP` /
  `BULK_PUBLIC` / `BULK_AIRPORT` 与探测阈值、间隔、冷却
- 调整 文档 —— `docs/TOOLS.md` 目录树与「会改设备状态吗」表加入 `bulk-guard.sh`
  （只切策略组，不改配置）

### 门面统一批次（2026-10-21）

在「README 收敛批次」之后再收一轮：门面压到与 GSAuxiliary 同款的七节，
开发者内容继续下沉 `docs/`，门面资源（logo / 社交预览）统一由 `assets/icon.svg` 渲染。

- 调整 文档 —— 根 README 收敛为七节（这是什么 / 环境要求 / 使用 / 反馈 / 免责声明 / 开源鸣谢 / 许可证）；
  顶部不写「一句话」引言块，定位由副标题承担（对齐 GSAuxiliary）
- 调整 文档 —— 三个域的速查表（目录 / 干什么 / 适合谁）下沉 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §1；「设计原则」全文下沉同篇 §1.1；
  README 只留一句话概述 + 链接
- 新增 工具 —— `tools/make_social_preview.py`：自带 SVG 渲染器，从 `assets/icon.svg` 生成
  `assets/logo.png`（512×512）与 `assets/social-preview.png`（1280×640），不依赖 cairosvg 等外部程序
- 调整 资源 —— `assets/logo.png` 改为由 `assets/icon.svg` 渲染，图形不再有两份正本
- 调整 文档 —— `docs/DOC-RULES.md` 正本映射表与 `docs/README.md` 索引同步；
  各仓 docs 里指向根 README 章节的文字引用改指新正本
- 调整 仓库 —— GitHub 仓库描述与话题改成面向使用者的口径（与 README 副标题同调）

---

## [0.1.0] — 2026-10-21

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

### 整理批次（2026-10-21）

- 调整 工具 —— `tools/check-docs.py` 的跳过目录补 `.codegraph/`（`.work/` 此前已跳过），
  本地索引不再参与版本库文档检查。
- 清理 工作区 —— 删除 `.work/readme-refresh/`（README 门面生成的一次性中间产物，
  最终 logo / 社交预览已入库）。
