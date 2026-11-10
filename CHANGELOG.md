# 更新日志

> **一句话**：本仓的开发者记录 —— 每个版本改了什么、为什么、怎么验。
> 顶部的版本命名规则是**摘要**，**正本见 [docs/VERSIONING.md](docs/VERSIONING.md)**。

版本号形如 `X.Y.Z`（`v` 前缀只属于 git tag，文档与文件名不带）。**有功能更新进次版本（+0.1.0，补丁归零）；没有功能更新进补丁版本（+0.0.1）。**

---

## [未发布] — 待发 0.5.0

> 本次含新功能（`traffic-stats.sh --summary`），按 [docs/VERSIONING.md](docs/VERSIONING.md) §1
> 走「次版本」那档：发版时把本段标题改成 `## [0.5.0] — <发版日期>`，并补
> `docs/release-notes/0.5.0.md`。**本次未打 tag、未发版。**

### 设备内核升级到 v1.19.33 后的当前值同步（2026-11-10）

- `README.md` §「已验证环境」：设备 mihomo 当前值由 `v1.19.28` 改为
  `v1.19.33`（`CrashCore.upx` 15,007,192 B，2026-11-10 11:06 装入，运行态 `/version` 同步）；
  原 `v1.19.32` 保留为「2026-10-20 短暂手动升级后被自动更新回退」的带时点历史记录。
- 为什么：DOC-RULES §6 要求「当前值类描述必须随实际变化同步」；README 这句是门面里
  唯一的设备内核当前值，升级后不改就会让后来者按旧核排查。
- 验证（设备只读复验）：`CrashCore.upx -v` = `Mihomo Meta v1.19.33 … go1.27.3`、
  `cfg core_v=v1.19.33`、`curl /version` = `{"meta":true,"version":"v1.19.33"}`、
  核心进程数 1。探针 cron 与 `openwrt/traffic-stats.sh` 未受影响，
  `stats/2026-11-10.tsv` 升级后继续写入。`openwrt/post-sc-update.sh` 本次未改。

### traffic-stats.sh 新增 --summary 跨天分账（2026-11-06）

- 新增 `openwrt/traffic-stats.sh --summary`：把 `$STATS_DIR` 下所有 `YYYY-MM-DD.tsv`
  合成一张账 —— 先按「机场出口 / 直连 / 兜底」三分类分账，再给按组合计 top15 与域名 top20。
  `--report` 只看单日，答不了「这段时间机场流量被谁吃了」
- 分账口径可覆盖：`STATS_AIRPORT_GROUPS` / `STATS_DIRECT_GROUPS`（`|` 分隔的扩展正则，
  匹配 tsv 里的策略组名）。默认是一份通用占位口径 —— 组名换了自己覆盖，不用改脚本
- 只读 `$STATS_DIR` 下的 tsv：不采样、不落盘、不写状态；`--report`（按天打印）与
  `STATS_DIR` / `STATS_FLUSH_MIN`（默认 10 分钟攒批，0 = 逐分钟）行为一行未动
- 为什么：跨天看「机场 vs 直连 vs 兜底」占比，才能判断某段流量该不该走机场；
  逐日 `--report` 加总要人肉做，且组名一多就漏
- 验证：设备 4 天数据跑 `--summary` —— 总量 120.7 MB、机场出口 40.8 MB（33.8%）、
  直连 69.1 MB（57.2%）、兜底 10.8 MB（9.0%），三段相加等于总量，与逐日 `--report` 对得上

### bulk-guard.sh 空闲计时缺陷修复（2026-11-06）

- 修 `LAST_MOVING` 的缺省值：`LAST_MOVING=$(state_get last_moving)` 之后原写
  `LAST_MOVING=${LAST_MOVING:-0}`，状态里没这个键时取 0 → `NOW_TS - LAST_MOVING`
  恒等于整个 epoch，回切判据 `-ge $IDLE_SWITCH` 与「清已试」判据 `-gt $IDLE_SWITCH`
  同时被击穿。改为 `case "$LAST_MOVING" in ''|0|*[!0-9]*) LAST_MOVING=$NOW_TS ;; esac`
  （两处：状态读取段、回切判定段）
- 修 `switch_airport()` 只写 `cooldown_until` 不写 `last_moving` —— 切到机场那一刻没被
  记为「刚活动」，回切空闲仍从上一个会话的时间戳起算；补 `state_set last_moving "$NOW_TS"`
- 新增可覆盖变量 `BULK_MIN_BPS`（空闲探测阈值，bytes/sec），内置默认仍是 800000。
  设备侧 `device.conf` 按实际链路设为 600000（≈持续 5.9 Mbps），
  `BULK_RETURN_COOLDOWN` 由 1200 调到 3600
- 为什么：设备日志出现「机场已空闲 29898910 分钟」（≈57 年），组每 20 分钟在机场与公共池
  之间来回切，机场停留形同虚设。阈值贴着实际速率是放大器 —— 探测值在阈值两侧跳，
  就会一直重演「切过去 → 判空闲 → 切回来」
- 验证：`sh -n` 过、仓内与设备 md5 一致；设备跑 `--status` 读到「回切: 机场停留 3600s
  且空闲 300s」「阈值: 585 KB/s」（= `BULK_RETURN_COOLDOWN=3600` 与 `BULK_MIN_BPS=600000`
  已生效），`--dry-run` rc=0 无异常动作；旧版日志里「机场已空闲 29898910 分钟」这类
  五位数空闲分钟不再出现
- 文档：[docs/PITFALLS.md](docs/PITFALLS.md) P45、[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) §16、
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §3.5 / §4.6、[docs/TOOLS.md](docs/TOOLS.md) 工具表、
  [openwrt/conf/device.conf.example](openwrt/conf/device.conf.example)、[openwrt/README.md](openwrt/README.md)

### post-sc-update.sh 内核校验路径动态探测（2026-11-10）

- 修 `openwrt/post-sc-update.sh` 验收段（原 :196-198）：`CORE_BIN` 默认
  `$CRASHDIR/CrashCore.raw`，`if [ -x "$CORE_BIN" ]; then "$CORE_BIN" -t …; fi` 在只有
  `CrashCore.upx`（ShellCrash 1.9.5beta3 起精简 / 标准版）的设备上条件不成立 → **静默跳过**
  `-t` 校验、日志仍写「===== 5. 验收 =====」。改为 `CORE_BIN` 显式覆盖优先，否则按
  `CrashCore.upx` → `CrashCore.raw` → `$RUNTIME_DIR/CrashCore` 顺序探测第一个 `[ -x ]` 内核，
  找到 `log "配置校验内核：$CHECK_BIN"` 再跑 `-t`，三者都不在显式 log 告警。
  `:175/:189` 启动链路 `pidof "$CORE_PROC"` 与 `:31` 配置覆盖白名单一行不动。
- 为什么：内核文件名随版本分支变，写死任一个都会漏另两种布局；跳过分支不留日志会让巡检假绿。
  设备 2026-11-10 实况＝仅 `CrashCore.upx`（10,283,068 B / v1.19.28）+ 运行态软链。
- 验证：`sh -n` rc=0；五场景 fixture 全过（upx 优先 / 仅 raw 兼容 / 仅软链回退 / 全无告警 /
  显式覆盖不回归）；改后 226 行纯 LF、md5 `8e908bdcb3773b3af5c97a18f476a08e`；设备部署副本
  已按「备份 `/root/post-sc-update.sh.bak-shellcrash-status-20261110` → `sh -n` → 原子 `mv` → md5 复核」
  同步为同值，核心进程数仍 1（**未重启**）。
- 文档：[docs/PITFALLS.md](docs/PITFALLS.md) P46、[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) §17、
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §3 / §4.5、[docs/TOOLS.md](docs/TOOLS.md) 工具表。

## [0.4.0] — 2026-11-06

### 门禁脚本 GBK 控制台自毁修复（2026-11-04）

- 修 `tools/check-docs.py`、`tools/check-secrets.py`、`tools/github-setup.py`、`tools/make_social_preview.py` 的结论行 `✓` / `✗` / `⚠` → ASCII `[OK]` / `[FAIL]` / `[!]`：Windows 中文控制台
  （cp936）下这些字符不在 GBK 码表，`print` 抛 `UnicodeEncodeError`，脚本即便检查全过也以
  **退出码 1** 结束；`python -I` 会忽略 `PYTHONIOENCODING` / `PYTHONUTF8`，环境变量救不回来，
  只能改脚本本身。
- 入口补兜底 `if hasattr(sys.stdout, "reconfigure"): sys.stdout.reconfigure(errors="replace")`：
  以后任何非 GBK 字符降级成 `?`，不再让门禁误判失败。
- 验证：`python -I` 逐个跑上述脚本 → `[OK] …`、退出码 0、无 traceback；反证：把 `✓` 改回原样，
  同一命令退出码 1 并抛 `UnicodeEncodeError`。

### 大流量守卫补「空池」判定（2026-11-04）

- `openwrt/bulk-guard.sh`：新增 `pool_real()` / `api_ok()` / `pool_cands()`。
  公共池只剩内置 `DIRECT`/`COMPATIBLE` 时组等价直连 —— 探测域 `proof.ovh.net`
  直连是通的，原来的存活/吞吐检查看不出问题，Telegram（按 IP 段指进本组）
  空池时会静默走直连断掉。现在池子空且控制 API 可用就立刻切机场
- 回切前必须用 `pick_live_node_n`（最多 3 个候选）找到 gstatic + 大流量探测
  双通的节点，找不到就留在机场，每 6 小时记一次 `WARN`
- 候选统一走 `pool_cands()`：只取池内真节点 + 吞吐缓存排序，修掉「把缓存里残留的
  `COMPATIBLE` 当节点 `PUT`、被控制 API 拒绝后刷 ERROR」的问题
- `--status` 多打一行「公共池真节点」；验收开关 `BULK_TEST_POOL_EMPTY=1`
  （只影响判定，不改设备状态）
- 文档：ARCHITECTURE §4.6 第 4–6 条、PITFALLS P43、TOOLS 工具表、
  MAINTENANCE §3.8 B6/B10 及新增 B11–B12

### 部署文档闭环与门面脚本依赖提示（2026-11-04）

- `openwrt/README.md` §3：配置改为单文件落点 `/etc/openwrt-ops/device.conf`，
  与脚本查找路径一致（重装时不再嵌套成 `conf/device.conf` 而静默不加载）
- §3 补 `traffic-stats.sh` 的 scp / chmod / cron（0.3.0 新增脚本后部署清单漏项）
- `tools/make_social_preview.py` 缺 numpy/Pillow 时给出安装提示，不再裸 traceback

### P3 清理（2026-11-04 审查遗留项）

- `openwrt/guardian.sh` 的 `/tmp` 清理循环加路径形态防护：`TMPFS_CLEAN_FILES` 只接受
  `/tmp/*`，其余路径记 SKIP 日志并拒绝删除（配置手滑写宽路径时不再整目录删）
- `openwrt/traffic-stats.sh` 删死变量 `CFG`（从未被引用）
- `openwrt/conf/device.conf.example`：`TMPFS_CLEAN_FILES` 注释值与内置默认对齐（补
  `/tmp/core_test_out.txt`）；补 recover-now.sh 专属键（`DNS_HIJACK_TABLES` / `RC_LOCAL` /
  `GUARDIAN_PATH` / `RECOVER_LOG` / `DIRECT_TEST_HOST` / `PROXY_TEST_URL` / `PROXY_TEST_URL2`）
  与 `STATS_FLUSH_MIN`
- `README.md` 删掉过度声明的 `uhttpd` / `ubus` / `rpcd` 依赖（脚本零引用）

## [0.3.0] — 2026-11-01

### 守卫脚本 bug 奇偶同步（2026-11-01）

- `tools/check-secrets.py` 对齐 ClientTriage `c3a3952` 已修的漏报 ——
  `re.search` 改 `finditer`（同一行多个命中全查）、`--all` 遵循 `.gitignore`；
  分叉差异保留，加出处头注释（`0d5be7d`）
- `tools/check-docs.py` 对齐 ClientTriage `c3a3952` / WindowsRemoteOps
  `156562c` 已修的四处功能性 bug —— BOM 首锚点、跨盘符 relpath 崩溃、
  冻结锚点误报、引言块只认头部；分叉差异保留，加出处头注释（`3691820`）
- 文档脱敏 —— 守卫文档与旧目录示例改占位（`bc054f0` / `ac9ca2b`）

### 闪存降频：统计落盘攒批（2026-11-01）

- 优化 `openwrt/traffic-stats.sh` 写盘节拍 —— 旧版只要有增量就**每分钟全量重写**
  当日 tsv（overlay 上一天最多 1440 次读改写，是本仓路由器侧最大的闪存磨损点）；
  改为差值先攒进 `/tmp` 的当日缓冲（tmpfs），默认每 `STATS_FLUSH_MIN=10` 分钟
  聚合落盘一次（一天 ≤144 次；`0` 可退回逐分钟），**tsv 格式与聚合口径不变**，
  采样 / 种子 / 差值逻辑一行未动
- 落盘节拍记在 `$RUNTIME_DIR/traffic-stats.buf.ts`（锚点在首个差值进缓冲时起算，
  flush 后刷新）—— 不能拿缓冲文件 mtime 当锚点：它每分钟被追加刷新，永远
  「刚写过」，间隔永远等不到（沙箱实测踩到，T7b 断言覆盖）
- 重启丢数据的窗口从 ≤1 分钟变为 ≤1 个落盘间隔（缓冲在 tmpfs）——
  对「大流量归因」无感，已写进脚本头注释与 TROUBLESHOOTING §16 已知偏差
- 修 `docs/TROUBLESHOOTING.md` §16 第 3 步命令 —— `cut -d= -f2 || echo 9999`
  在 `device.conf` 没配 `CTRL_PORT` 时不触发（cut 空输入退出码 0），端口拼空；
  改为先取值再 `${port:-9999}`（2026-11-01 真机复现）；§16 补「cron 行被
  ShellCrash 重写冲掉」与「聚合落盘间隔」两条实测原因
- 修 `docs/ARCHITECTURE.md` §4.1 总览矩阵 —— 「写流量统计与采样状态」的 ✅
  原来错位在 post-sc-update 列，挪回 traffic-stats 列
- 沙箱验证 —— 路由器 `/tmp` 新旧版对照 29 项断言全绿：首见记种子（旧版首见
  虚高 100/200 复现，差值即本轮修复点）、缓冲/锚点/自动落盘（FLUSH_MIN=1
  实测 60 秒到点落盘）、跨天缓冲各归各的日期、`--report`、缺 secret 的
  stderr、幂等复跑、终态 state 新旧一致
- 部署 —— `/etc/ShellCrash/traffic-stats.sh` md5 `703ecbc0…` 与仓库一致；
  **补回 cron 行** `* * * * * /bin/ash /etc/ShellCrash/traffic-stats.sh`（上轮部署后
  于 10-31 12:36 被 ShellCrash 重写 crontab 冲掉，stats 停更至今；本轮按
  TROUBLESHOOTING §16 第 4 步补回），真机采样 / 落盘 / `--report` 全部通过

### 新增 `traffic-stats.sh`：按「策略组 + 域名」记流量（2026-10-30）

- 新脚本 `openwrt/traffic-stats.sh`（cron `* * * * *`）：采样 mihomo `/connections`，
  按「命中的策略组 + 域名」累计上下行字节，落到 `/etc/ShellCrash/stats/YYYY-MM-DD.tsv`
- 为什么需要：nlbwmon 只能按 LAN 主机记账；而「机场流量被谁吃了」「公共池到底承载了多少」
  这类问题要按站点/组归因。mihomo 不保存历史，只能自己采样
- 增量按连接 id 记差值（`/connections` 的字节是连接累计值，直接累加会重复计数）；
  每轮就地汇总进当日文件（不追加原始行），只留 31 天
- 资源：常驻 0（cron 拉起即退），实测峰值 VSZ **1.3 MB**、可用内存前后差 ≈1 MB（噪声级）；
  采样一次 `/connections` 约 6 KB
- 踩到两个 BusyBox 坑，都写进脚本注释：① `sed` 替换里不支持 `\n` 插换行 ——
  改成整段交给 awk 内存里切分；② `FNR==NR` 判别「旧状态文件」在**首轮状态为空**时失效，
  新样本会被当成旧状态全部跳过（状态永远建不出来）—— 改用 `FILENAME == oldfile`
- 已知偏差：两次采样之间开完就关的短连接会漏掉（偏低估小请求），
  总量仍以 nlbwmon 为准

### 增量审查修复（2026-11-01）

- 修复 `openwrt/traffic-stats.sh` 不读 `device.conf` —— 控制 API 写死
  `127.0.0.1:9999`、目录写死 `/etc/ShellCrash`，违反「环境变量 → device.conf →
  内置默认值」的加载顺序（AGENTS §2）；补齐与其余脚本同一段配置加载，
  `CTRL_HOST` / `CTRL_PORT` / `CRASHDIR` / `RUNTIME_DIR` / `API_CFG` 可配
- 修复 同脚本的 secret 来源 —— 原从运行态 `config.yaml` 的 `secret:` 行提取
  （值里带单引号时会带着引号去鉴权）；改为与 guardian / bulk-guard 同源读
  `ShellCrash.cfg` 的 `secret=` 行（对齐 ARCHITECTURE §4.7「secret 一律现读」的
  口径），读不到时向 stderr 提示一句
- 修复 同脚本的首见连接计数 —— `/connections` 的字节是连接累计值，原实现对
  首见连接按「新值 − 0」计差值，核心重启 / 状态丢失后会把连接建立以来的字节
  一次性计入；改为首见只记「种子」，从下一次采样起计增量（PITFALLS P42）
- 加固 同脚本 trap 补 `INT` / `TERM` / `HUP`（与两个守卫一致）：被杀时也清
  `.delta` / `.new` 残留，避免下一轮把残留差值重复计入当日文件
- 文档 —— 10-30 新增脚本后没跟上的现役事实对齐：脚本计数五 → 六
  （`docs/ARCHITECTURE.md`、`docs/UPSTREAM.md`、`docs/MAINTENANCE.md`、
  `openwrt/README.md`）；`docs/ARCHITECTURE.md` §3.5 键表与 §4.1 总览矩阵补
  `traffic-stats.sh` 列；`docs/TOOLS.md` 目录树 / 会改表补 `traffic-stats.sh` 与
  `tools/check-secrets.py`；`docs/TROUBLESHOOTING.md` 补「流量统计不更新」一节

## [0.2.1] — 2026-10-26

面向用户的说明见 [docs/release-notes/0.2.1.md](docs/release-notes/0.2.1.md)。

### 全仓审查修复（2026-10-26）

- 修复 `openwrt/recover-now.sh` 的 DNS 劫持表解析 —— `DNS_HIJACK_TABLES` 原本是
  `inet googleroute inet shellcrash ...` 的空格串，循环把每个词当独立表名；
  `nft list table googleroute` 缺 family 时默认查 ip 族，而表是 inet 族，
  永远删不掉，「先摘 DNS 劫持」这步等于没做。改为 `family:表名` 并真正按对解析
  （PITFALLS P40）
- 修复 同一脚本的 WAN 诊断 —— `ip -brief addr` 在 BusyBox 上不可用，错误被
  `2>/dev/null` 吞掉后误报「WAN 没地址」并触发 `ifup wan`；改为先探测能力再兜底
  `ip -4 addr`（PITFALLS P41）
- 修复 端口就绪判断 —— `netstat | grep ":$PORT"` 是子串匹配，1053 会命中 10530-10539；
  改为 `[:.]$PORT[[:space:]]`
- 修复 `openwrt/guardian.sh` 健康探测 —— 只看 `%{time_total}`，节点被封时的
  「快速失败」被判健康；改为同时看 `%{http_code}`，非 2xx/3xx 按劣化处理
- 修复 两个守卫的 URL / JSON 转义 —— 节点名含 `"` `\` `%` `#` `?` 时切组请求失败；
  `enc()` 补 `%`/`#`/`?`/`&`，`put()` 对名字做最小 JSON 转义
- 修复 两个守卫的 secret 读取 —— 读不到 secret 时静默失效（全部 401 被当成
  「组不存在」跳过）；启动时显式 `ERROR` 告警
- 修复 `openwrt/post-sc-update.sh` 的验收统计 —— 「分组数」把 proxies 条目也算进去、
  「规则数」统计所有顶层列表项；改用 awk 按 `proxy-groups:` / `rules:` 段定界
- 修复 `mihomo/mihomo_api.py` —— `/rules` 返回 `{"rules":[...]}` 未解包，
  `rulestats` 对 dict 切片必崩、`summary` 误报 total=1
- 修复 `mihomo/rule_audit.py` —— proxies.json 缺失时 `eg="?"` 恒判通过（假绿灯）；
  `?` 不再算通过，报告头部声明模拟范围
- 修复 `cdn/qq_domain_classify.py` —— 全量累积日志里用子串匹配，父域/兄弟域互相污染；
  改为锚定完整域名
- 修复 `cdn/qq_cdn_probe.py` —— DNS 应答名的「标签+压缩指针」编码未处理（后续记录错位）；
  TLS 之后的 HTTP 异常误标为 TLS
- 修复 `tools/check-secrets.py` —— 本机路径豁免是整行的；改为只豁免命中片段，
  git 失败时不再打假绿
- 文档 —— `openwrt/conf/device.conf.example` 补 `PATCH_SPEC` 说明（post-sc-update
  恢复哪些补丁、标记不能含空格）
- 验证 —— 全量 `sh -n` ✓、`py_compile` ✓、`check-secrets.py` ✓；
  `bulk-guard.sh` / `post-sc-update.sh` 部署后 `ash -n` ✓、md5 与仓库一致，
  `post-sc-update.sh check` 三处标记全部 OK，`bulk-guard --dry-run` rc=0

### 大流量守卫体检修正（2026-10-24）

- 修复 `openwrt/bulk-guard.sh` 三处叠加盲区（2026-10-23 Telegram 下载停滞
  一整天不切机场的根因，详见 [docs/PITFALLS.md](docs/PITFALLS.md) P37–P39）：
  1. `pool_health()` 改为以**实际承流节点 now** 为准 —— 原来只盯 `fixed`，
     而被钉节点过不了核心 gstatic 健康检查时 url-test 会漂走（fixed=公共-01
     OVH 通、now=公共-09 全死，守卫每轮都「健康」）。换钉候选改要求
     gstatic + 大流量探测**双通**，钉住后复核 `now` 真的跟上，钉不住换下一个
  2. 机场停留冷却 600s → **1200s** —— 原值恰好等于 `*/10` cron 周期，
     切机场的下一轮 cron 必然赶上冷却到期「刚切就切回」；
     `device.conf.example` 样例同步
  3. 空闲探测**连续 2 次无效**（`bad_probe` 计数）即切机场并推进
     `last_probe` —— 原来无效不判定、`last_probe` 不推进，死透的承流节点
     要等 2 小时才有下一次探测机会
- 验证 —— `sh -n` ✓（本机与路由器各一遍）；路由器实跑 `--status`
  （机场停留 1200s 生效）、`--dry-run` 一轮无异常动作、实跑一轮对
  死节点完成换钉；部署后 cron 轮按新逻辑正常切回/体检
- 部署 —— 已同步 `/etc/ShellCrash/bulk-guard.sh` 与
  `/etc/openwrt-ops/device.conf`（`BULK_RETURN_COOLDOWN=1200`）

### 文档正本与守卫规则（2026-10-24）

- 新增 `docs/DOC-RULES.md` 变更触发矩阵一条 —— **修一个缺陷必须给对应正本补一条**
  （只改代码不改正本，下次还会踩同一个坑）
- 新增 `docs/PITFALLS.md` P31–P35 五条 —— 阈值减半、`mkdir` 实例锁、
  名字进 shell 的转义、check 模式必须先判 mode 再动作、同落点变体互相覆盖
- 新增 `docs/SECRETS.md`「推送前脱敏规则」通用章节 —— 凭据 / 本机用户目录 / 真实邮箱
  三类拦截面与三条放行口径；`tools/check-secrets.py` 相应加占位用户名放行
- 新增 `tools/check-secrets.py` —— 把 CI 里内联的 grep 凭据扫描换成统一守卫脚本

### 大流量守卫二次校验（2026-10-23）

- 修复 `openwrt/bulk-guard.sh` —— 新增 `node_bulk_alive()`：`/delay` 必须返回
  HTTP 200 **且响应体含 `"delay"`**，探测 URL 用 `PROBE_URL`（`proof.ovh.net`）
  而不是 `ALIVE_URL`（gstatic 204）。`pool_health()` / `pick_live_node()` /
  `handle_slow()` 全部改用它；未钉住时也检查 URLTest 当前节点
- 根因 —— 公共节点可以过 gstatic 健康检查，但到 OVH 的 TLS 握手 EOF / HTTP 502；
  原逻辑只看 HTTP 状态码，会把「能出网但不能跑大文件」的节点钉进 `📺 大流量`
  （2026-10-23 实测 10 条公共节点里 02/03/06 属于这一类）
- 验证 —— `sh -n` ✓；路由器实跑 `--status` 显示钉住 `公共-08`，
  `proof.ovh.net` 4MB 实测 1.9–2.2 MB/s（修复前钉到 `公共-02` 时 000）

### 守护实例锁（2026-10-24）

- 新增 `openwrt/guardian.sh` 实例锁 —— 与 AX 仓同一处问题：整轮可能超过 cron 间隔，
  叠轮会让两轮同时切策略组、同时写状态文件。锁形状照抄 `bulk-guard.sh`：
  `mkdir` 原子建锁 + pid/ts + 600 秒过期回收 + `trap` 清理
- 验证 —— `sh -n` ✓；并发跳过与死 PID 过期回收在本地验证过

## [0.2.0] — 2026-10-23

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
