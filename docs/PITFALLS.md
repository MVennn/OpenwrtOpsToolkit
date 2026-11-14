# 踩坑总汇

> **一句话**：这工具箱能跑起来，是因为**这些坑都踩过了** ——
> 每条写清「现象 → 根因 → 下次怎么避」，是全仓踩坑经验的**正本**。

**读法**：现象那一行就是搜索词。按现象在本文里搜，命中即是。
每条都注明**代码或记忆依据**，方便自己回去核对。

相关：[TROUBLESHOOTING.md](TROUBLESHOOTING.md)（按现象排的完整排查流程）、
[ARCHITECTURE.md](ARCHITECTURE.md)（机制）、
[`memories/`](../memories/MEMORY.md)（记忆原文）。

---

## 1. 设备与系统层

### P1 `/tmp` 是内存盘，写大文件会把自己撑爆

- **现象**：设备跑久了突然整机重启；`df -k /tmp` 显示接近 100%；内核日志里 OOM。
- **根因**：OpenWrt 的 `/tmp` 是 **tmpfs**，占的是 RAM 不是闪存。
  往里放内核测试包、订阅压缩包、临时配置备份，很快就写满；
  写满之后不是「磁盘满」，而是**内存被占光 → OOM → 看门狗整机重启**。
- **解法**：`guardian.sh` §6 每次巡检都 `df -k /tmp`，
  用量 ≥ `TMPFS_WARN_PCT`（默认 80%）就打警告并清理 `TMPFS_CLEAN_FILES` 里的白名单文件。
- **下次怎么避**：大文件往 overlay 放，别往 `/tmp` 放；
  下载内核包时优先落到 `/root` 或 overlay 挂载点。

### P2 `/var` 是指向 `tmp` 的**相对**软链，运行时目录被误删会连累 dnsmasq

- **现象**：重启后 dnsmasq 起不来，内网解析全失败；日志里报
  `/var/etc/dnsmasq.conf.*` 不存在。
- **根因**：没开 `CONFIG_TARGET_ROOTFS_PERSIST_VAR` 时，`/var` 是指向 `tmp` 的**相对软链**
  （`package/base-files/Makefile` 里 `$(LN) tmp $(1)/var`）。
  所以 `/var/etc`、`/var/lib` 这些目录**实际在 tmpfs 上**，
  而 dnsmasq 依赖 `-C /var/etc/dnsmasq.conf.*` 读自己的配置 —— 目录没了，dnsmasq 直接退。
- **解法**：`rc.local` 开机时按 `VAR_RUNTIME_DIRS` 兜底重建这十来个目录
  （`/var/etc` `/var/lib` `/var/run` `/var/lock` `/var/state` `/var/spool` `/var/shm` `/var/tmp`
  `/var/overlay` `/var/sysinfo` `/var/odhcpd-piodir` `/var/resolv.conf.d` `/var/log`）。
- **下次怎么避**：知道 `/var` 在 tmpfs 上；任何「重启后某个服务莫名其妙起不来」，
  先查 `/var` 下那几个目录在不在。

### P3 开机有一段「连上却没网」的死窗口

- **现象**：设备重启后几分钟内全家上不了网，过一会儿自己好了。
- **根因**：含 **DNS 劫持**的 nft 表如果在核心起来**之前**加载，
  内网所有 DNS 请求会被指向代理的 DNS 端口，而那个端口**还没人监听** ——
  解析全部超时。表现和「代理挂了」一模一样。
- **解法**：`rc.local` 把表分成两拨：
  不含 DNS 劫持的**开机就加载**；含 DNS 劫持的**等核心 DNS 端口（默认 1053）就绪再加载**，
  等不到就**不加载**，交给 `guardian.sh` §4 在核心起来后补。
- **下次怎么避**：自己加 nft 表时，先问一句「这张表劫持 DNS 吗」——
  劫持的就别在开机阶段加载。

### P4 `start.sh start` 会重写 crontab，把看门狗行冲掉

- **现象**：重启或跑过恢复脚本后，守护进程不再运行；面板里选的节点也不落盘。
- **根因**：ShellCrash 的 `start.sh` 在启动/停止时会重写 crontab。
  它不认识本仓的三行 cron（`guardian.sh` / `start_legacy_wd.sh` / `task.sh 106`），
  重写时就没了。其中 `task.sh 106` 是**每 10 分钟保存面板选择**用的 ——
  丢了会导致「选中的节点不落盘」。
- **解法**：三处都补了 —— `guardian.sh` 收尾的 cron lifeline、
  `recover-now.sh` §5、`post-sc-update.sh` §2。
  补的方式都是**按关键字 grep，缺了才追加**，不会重复写。
- **下次怎么避**：任何会跑 `start.sh` 的动作之后，都 `crontab -l` 看一眼那三行还在不在。

### P5 `start.sh` 可能把 fw4 留在「半加载」状态

- **现象**：`start.sh` 跑完之后设备「连得上但没网」，重载防火墙就好了。
- **根因**：`start.sh` 内部会改防火墙规则（走 fw4），
  中途被打断或与自建规则冲突时，fw4 生成出来的 nft 规则集处于半成品状态。
- **解法**：`recover-now.sh` §4.1 在重生成配置之后**固定**跑一次
  `/etc/init.d/firewall restart`，然后检查 WAN 口地址与默认路由，缺就 `ifup wan`。
- **下次怎么避**：任何改完防火墙相关配置的步骤，后面都跟一句 `firewall restart`。

### P6 nft 的 **nat 链不允许 `reject`** —— 命令静默失败

- **现象**：想让某个 UDP 流量直接被拒，规则写了但**一点效果都没有**，
  `nft list table` 里也看不到那条规则。
- **根因**：nftables 的 **nat 链只支持 `accept` / `drop` / `queue` 等少数 verdict**，
  `reject` 写进去会**静默失败**（不报错，规则也没生效）。
  上游 ShellCrash 的 `starts/fw_nftables.sh` 里就有一处同款写法。
- **解法**：把 `reject` 放到 **filter 链**（如独立的 `inet quicguard` 表）里做。
- **下次怎么避**：写完 nft 规则，`nft list table inet <表>` 确认规则**真的在**，
  别信「命令没报错」。

### P7 `nft -f` 的 `add table` **不替换**已有表

- **现象**：改了 `/etc/<表名>.nft` 的内容，重新 `nft -f` 加载，**规则还是旧的**。
- **根因**：`nft -f` 里的 `add table` / `add chain` 语义是**「不存在就建」**，
  对已存在的表**不做替换**。文件改了不等于内存里的表改了。
- **解法**：改完先 `nft destroy table inet <表名>`，再 `nft -f <文件>`。
- **下次怎么避**：记住「改 nft 文件 → destroy → reload」这三步是成套的。

### P8 守护只在表**缺失**时补载 —— 表内容写错永远不会被纠正

- **现象**：nft 表里的规则写错了（比如漏了放行国内目标的那两条），
  守护跑了一晚上也没纠正。
- **根因**：`guardian.sh` §4 的判据是 `nft list table inet <表>` **在不在**。
  表在 → **什么都不做**。它只管「表没了」，不管「表里的内容对不对」。
- **解法**：内容错了只能**手动** `nft destroy table` + `nft -f`；
  或把该表从守护的补载清单里去掉，改由 `rc.local` / 恢复脚本负责。
- **下次怎么避**：别指望守护能纠错 —— 它是「缺失自愈」，不是「配置校验」。

### P9 `fake_ip_filter` 里一个空行就能让内网解析全挂

- **现象**：WiFi 连上了，但**所有域名都解析不了**，像「连上却没网」。
- **根因**：fake-ip 过滤文件里如果混进了**空行**（常见于「追加一行时手滑多敲了个回车」），
  ShellCrash 会把它原样塞进 `fake-ip-filter`，
  mihomo 的 DNS 因此异常且不自愈 → 内网解析全失败。
- **解法**：`recover-now.sh` §1 每次都做防御性清洗 ——
  备份成 `fake_ip_filter.bak.<时间戳>`，然后去空行、去注释、去行尾空白、去重复项。
- **下次怎么避**：改这个文件**只追加不手改**；实在要手改，改完 `grep -c '^[[:space:]]*$'` 看一眼。

---

### P31 守护的耗时判据取 max 后又除 2，阈值被静默减半

- **现象**：节点已经劣化到全站超时，3.5 / 3.6 仍不触发复位。
- **根因**：`awk '{t+=($1>$2?$1:$2)} END{printf "%.1f", t/2}'` —— `$1` / `$2` 是同一行的
  两个字段，取到 max 后又除了 2。实测 3.2 / 2.8 得 1.6，而意图是 3.2；
  `EXIT_MAX_SEC=3` 实际要真实 6 秒才触发。
- **解法**：取 max 后不除；阈值比较用 `ge_sec`（数值比较），不要用 case glob。
- **下次怎么避**：改阈值判据先用两组样本手算，再上机。

### P32 守护没有实例锁，`*/5` 的 cron 与最坏 300 秒的一轮会叠轮

- **现象**：日志里出现「已换到 A」，实际生效是 B；状态文件偶尔互相覆盖。
- **根因**：3.6 每个候选 `sleep 3` + 两次 15 秒超时，4 个候选就 132 秒；整轮可超过
  cron 间隔。两轮同时 `put` 策略组、同时写状态文件。
- **解法**：`mkdir` 原子建锁 + `pid` / `ts` + 600 秒过期回收 + `trap` 清理
  （与 `bulk-guard.sh` 同款），拿不到锁记一行日志后跳过本轮。
- **下次怎么避**：cron 周期可能小于最坏耗时的脚本，第一版就要有实例锁。

## 2. 代理与规则层

### P10 Redir（透明代理）**只代理 TCP**，UDP 全直出

- **现象**：某个站点「网页外壳能开，但 UI 加载不全」；无痕模式同样失败；
  同一时刻另一个浏览器却正常。
- **根因**：Redir 模式只转 **TCP**，**UDP 根本不进 mihomo**。
  浏览器优先用 HTTP/3（QUIC，UDP 443），QUIC 直出 WAN → 带本地出口 IP →
  目标站按地区把它降级或拒绝。Electron 类客户端默认不启用 QUIC，所以「你坏它好」。
- **解法**：全局阻断 UDP 443/8443（独立 `inet quicguard` 表），让客户端**回落 TCP**。
  代价与豁免见 P11。
- **下次怎么避**：浏览器类问题**先看传输层** —— 把 UDP 443 全局拦掉再复测；
  或在 mihomo 连接里看 `destinationIP` 与下载字节是不是停在半截。

### P11 全局阻断 UDP 443 会把**国内应用**的 QUIC 一起掐死

- **现象**：加了 QUIC 拦截之后，国内 App 的图**一张都出不来**，
  每张缩略图都先空几秒才慢慢显示。
- **根因**：全局 `udp dport {443,8443} reject` 不分目标。
  国内应用的 QUIC 被打掉后，**Linux 不把 ICMP 端口不可达交给应用** ——
  应用不知道失败，只能等握手超时才回落 TCP，表现为「一堆图慢慢出」。
- **解法**：阻断规则**必须给国内目标开豁免** ——
  链首放行国内目标集合（`ip daddr @inet shellcrash cn_ip return` /
  `ip6 daddr @inet shellcrash cn_ip6 return`），
  集合由 ShellCrash 维护，并且**要剔除目标站所在地区的边缘段**，
  否则目标站仍然拿不到 QUIC、仍会被按地区误判。
- **下次怎么避**：任何「全局阻断」类规则，都要问一句「国内目标怎么办」。

### P12 规则里的 `*.X` 只匹配**单标签**，`+.X` 才匹配多级

- **现象**：写了一条 `*.example.com` 的后缀规则，
  `a.example.com` 命中了，`a.b.example.com` **没命中**。
- **根因**：mihomo 规则语义里 `*.` 与 `+.` 不等价 ——
  `*.X` 匹配 `X` 的**单层**子域，`+.X` 匹配**多层**子域。
- **注意（工具的限制）**：`mihomo/rule_audit.py` 的模拟器用
  `value.lower().lstrip("+.*")` 剥前缀，
  **把 `*.X` 和 `+.X` 当成同一回事** ——
  所以审计报告**看不出**这个差别，需要自己回配置里核。
- **下次怎么避**：要覆盖多层子域就写 `+.X`；写审计报告时别把它当权威。

### P13 规则「**声明的分组**」≠「**实际命中的分组**」

- **现象**：明明配了「某域名走 A 组」，实际却走了 B 组；
  或者配了「广告拦截」，某个正常站点被拦。
- **根因**：mihomo 规则**先匹配先赢**。靠前的宽泛规则（`DOMAIN-SUFFIX` 大后缀、
  `RULE-SET,cn`、宽泛 `DOMAIN-KEYWORD`）会**遮蔽**靠后的具体规则。
  配置里写的目标是「声明」，真正生效的是**最早命中的那条**。
- **解法**：`mihomo/rule_audit.py` 就是算这个的 ——
  对每条域名规则，枚举所有可能更早命中的候选，取位置最靠前的那个当「实际生效目标」，
  与声明目标不一致的列为「顺序改道」，其中「一边是直连/拦截、另一边是代理」算**严重**。
- **下次怎么避**：改规则**顺序**前先跑一次审计，看「严重改道」条数；
  具体规则要放在宽泛规则**之前**。

### P14 运行中的 `cn.mrs` 可能比**文本** geosite 滞后

- **现象**：审计报告说某域名会走直连，运行时它却走了代理。
- **根因**：审计工具是**拿文本 geosite 列表模拟** `RULE-SET,cn` 的；
  而运行态用的是编译好的 `cn.mrs`。两者**可能不同步** ——
  文本里有、mrs 没收录的域名仍会走后面的规则。
- **解法**：审计结论当**方向性**证据；最终以运行态为准 ——
  用 `mihomo/mihomo_api.py conns` 看实际命中了哪条规则。
- **下次怎么避**：审计与实况对不上时，先怀疑**数据集版本差**，别急着改规则。

### P15 路由器自己的 `curl` **不走**透明代理

- **现象**：在路由器上 `curl` 一个境外地址，直接超时；
  但同一台设备上的客户端明明能上外网。
- **根因**：路由器本机发起的流量**不经过它自己的透明代理规则** ——
  透明代理拦的是**转发流量**，不是路由器自己发出去的包。
- **解法**：测代理链路要**显式指明代理** ——
  `guardian.sh` §3.5 / §3.6 的健康探测都用 `curl -x http://127.0.0.1:<PROXY_PORT>`；
  `recover-now.sh` §7 的直连与代理是**两条独立的 curl**。
- **下次怎么避**：在路由器上验证「某个出口通不通」，
  一律加 `-x`；不加 `-x` 测的是「路由器自己能不能出去」，是另一回事。

### P16 mihomo 的 `SAFE_PATHS` —— 手写运行态配置会被拒

- **现象**：手动往运行态配置目录写了一份改过的配置，核心拒绝加载或行为异常。
- **根因**：mihomo 有 `SAFE_PATHS` 机制 —— 对**运行目录**下的配置文件写入/加载有安全限制。
  运行态配置**不是给你手写的**，它由框架生成。
- **解法**：本仓**从不手写**运行态配置 ——
  `recover-now.sh` §3 的做法是**删掉** `config.yaml` / `error.yaml`，
  再交给 `start.sh` 重新生成；
  `guardian.sh` §5 的做法是跑 `task.sh hotupdate` 让框架重生成。
- **下次怎么避**：要改规则，改**源**（订阅扩展点 / 模板），不要改运行态产物。

### P17 守护日志在 tmpfs 上，重启即丢；还只留最后 60 行

- **现象**：出事后想查守护干了什么，日志里只有最近几分钟。
- **根因**：`GUARDIAN_LOG` 默认 `$RUNTIME_DIR/guardian.log`，
  而 `RUNTIME_DIR` 默认在 `/tmp`（tmpfs）—— **重启即失**。
  另外日志超过 200 KB 会自动截成**最后 60 行**
  （`guardian.sh` 第 174–177 行）。
- **解法**：要留证据就把 `GUARDIAN_LOG` 指到 overlay 上的路径；
  事后要查，**趁早** —— 200 KB 可能几小时就写满。
- **下次怎么避**：排查时先 `cp` 一份出来再看。

### P18 占位符默认值把「找不到组」变成「**跳过**」

- **现象**：配好了组名，守护却什么都不做；日志里也没有报错。
- **根因**：策略组名这类值的内置默认值是**空字符串**，
  每个动作前都有 `[ -n "$XXX" ]` 守卫，**空 = 跳过这项自愈**。
  这是**有意设计**（[SECRETS.md](SECRETS.md) §3）：组名对不上时，
  宁可什么都不做，也不要拿猜的名字去 PUT 别人的组。
- **解法**：想让某项自愈生效，就把对应键**配全** ——
  注意每项动作往往要**好几个键同时非空**（例如出口健康守卫要
  `POOL_GROUP` 与 `POOL_FALLBACK_GROUP` 都配了才生效）。
- **下次怎么避**：把「守护没动作」当成**配置问题**先查，别急着怀疑脚本坏了。

---

## 3. 工具与流程层

### P19 ShellCrash 官方脚本更新会**静默冲掉**本地打的补丁

- **现象**：官方更新之后，规则分类修正、CN 中间层、组顺序全没了，
  而且**没有任何报错**。
- **根因**：ShellCrash 的更新包**整包覆盖** `starts/` `libs/` `tools/` 等目录。
  你在 `starts/` 下打的钩子（改配置的脚本、防火墙补丁、看门狗）**被一起冲掉**。
- **解法**：`openwrt/post-sc-update.sh` 就是为此存在的 ——
  按**标记**认出被覆盖的文件 → 从 `PATCH_DIR` 的备份恢复 →
  补回 cron 三行 → 启动 → 验收。
- **下次怎么避**：**每次官方更新完都跑一遍** `post-sc-update.sh`；
  自己的补丁要在 `PATCH_DIR` 留一份带标记的备份。

### P20 `pgrep -f CrashCore` 会把它**自己**也匹配进来

- **现象**：查进程看到「两个实例」，以为核心起了两份。
- **根因**：`pgrep -f` 匹配的是**完整命令行**，
  而 `pgrep -f CrashCore` 自己就是一条含 `CrashCore` 的命令行 → **自匹配**。
- **解法**：确认真实实例要靠**端口** ——
  `netstat -lntp | grep -E ':7892|:9999|:1053'`，再对一下
  `/tmp/ShellCrash/shellcrash.pid`。
- **下次怎么避**：判断「起了几份」永远看监听端口，不看 `pgrep -f` 的数量。

### P21 awk 的正则遇到 **emoji** 可能匹配不到

- **现象**：用 `awk` 按组名（带 emoji）过滤配置，一行都没匹配上。
- **根因**：Git Bash / BusyBox 的 awk 在 **C locale** 下，
  含 emoji 的**正则**（如 `/^  - name: <emoji> 某组/`）可能匹配失败。
- **解法**：改用**字符串相等**（`$0 == "  - name: <emoji> 某组"`）或 `index()`。
- **下次怎么避**：awk 里要按中文/emoji 精确取值，一律用相等或 `index()`，不用正则。

### P22 `mihomo_log.py` 结束时会**把日志级别强制改回 `info`**

- **现象**：你本来把日志级别调成了 `warning`，
  跑完一次 `mihomo_log.py` 之后变成了 `info`，日志变多。
- **根因**：脚本用 `PATCH /configs` 改成 `debug`，
  收尾时**无条件** `PATCH` 回 `info` —— 它不记得原来是什么。
- **解法**：脚本跑完后自己再 `PATCH` 一次想要的级别。
- **下次怎么避**：用 `capture_live.py` 抓日志 ——
  它只在 `/logs?level=debug` 这条**订阅请求**上要 debug，
  **不改**核心的全局日志级别。

### P23 `latency_probe.py` 缺 secret 时**不报错**，只打印 `HTTP401`

- **现象**：探测全返回 `HTTP401`，看不出是「没配 secret」还是「secret 错了」。
- **根因**：`latency_probe.py` 用 `urllib` 自己发请求，
  secret 为空时**只是不加鉴权头**；而 `mihomo_api.py` 缺 secret 会**直接抛错**。
- **解法**：看到 `HTTP401` 先确认 `MIHOMO_SECRET` 有没有设、设对没有。
- **下次怎么避**：要么用 `mihomo_api.py`（缺 secret 会明说），要么自己在脚本外先导出 secret。

### P24 `qq_cdn_probe.py` 的 probe 段**硬编码**了一个 DNS 服务器

- **现象**：明明换了 DNS，解析结果还是没变。
- **根因**：`dns` 段按 `QQ_CDN_RESOLVERS` 轮着问，但 `probe` 段解析时
  **硬编码**用 `223.5.5.5`（不是系统 DNS，尽管那一行的标题写的是「系统 DNS 解析后」）。
- **解法**：要把「换了 DNS」这件事测出来，看 `dns` 段的输出，不要看 `probe` 段。
- **下次怎么避**：用 `dns` 段比解析结果，用 `probe` 段比连通性 —— 两段各管各的。

### P25 `rule_audit.py` 的 `findings.json` 落在**当前目录**

- **现象**：报告写到了指定路径，机器可读的结果却跑到了别处（或覆盖了旧文件）。
- **根因**：`findings.json` 的输出路径是**硬编码的相对路径**，
  写在哪取决于你在**哪个目录**跑的脚本。
- **解法**：跑之前 `cd` 到你希望它落地的目录。
- **下次怎么避**：跑审计前先 `cd` 到输出目录，一条命令的事。

### P26 `scan_rules.py` 里的 `SKIP` 常量**没有生效**

- **现象**：想「只看指向非 cn 的规则」，结果 cn 规则集那一大堆还是打出来了。
- **根因**：文件里定义了 `SKIP = {"cn"}`，注释也写着「只看向非 cn 的」，
  但**代码里从未引用它**。
- **解法**：用**匹配正则**过滤 ——
  `python3 mihomo/scan_rules.py 900 '<你的正则>'`，
  或用环境变量 `MIHOMO_RULE_PATTERN`。
- **下次怎么避**：别依赖那个常量；用命令行参数或环境变量。

### P27 API 调用失败会**重试很久**，看起来像卡死

- **现象**：控制 API 没起来时，工具**半天不出结果**，像挂住了。
- **根因**：`mihomo_api.api()` 默认 `tries=12`、每次间隔 0.6 秒；
  而 `rule_audit.py` 拉规则用的是 `timeout=90, tries=20` —— 最坏情况能等很久。
- **解法**：先单独探一下端口通不通（`netstat -lntp | grep 9999`），
  确认核心在再跑工具。
- **下次怎么避**：**先确认控制 API 活着**，再跑需要它的工具。

### P28 `/tmp` 清理是**白名单式**的，漏网的文件不会被清

- **现象**：`/tmp` 一直超 80%，但守护清了「该清的」还是超。
- **根因**：`guardian.sh` §6 只删 `TMPFS_CLEAN_FILES` 里列出的那几个路径，
  默认是四个（内核测试包、新版内核压缩包、核心测试输出、配置备份）——
  **不在名单里的一律不动**。
- **解法**：把自己产生的大文件加进 `TMPFS_CLEAN_FILES`（空格分隔）。
- **下次怎么避**：往 `/tmp` 放东西时，顺手把路径登记进这个白名单。

### P29 守护可能**不拉起**你以为它该拉的核心

- **现象**：核心进程没了，守护跑了几轮都没把它拉起来。
- **根因**：守护有「**人为停止**」的判定 ——
  进程不在、且**最近 30 分钟（`ALIVE_STALE_SEC`）没有存活记录**、
  且没有 pid 文件 → 判定为「你自己停的」，**刻意不拉起**，
  免得妨碍你维护。
  另外「进程在但 API 无响应」也**只报警不动手**（可能在热重载）。
- **解法**：确认要拉起时，手动 `sh $CRASHDIR/start.sh start`；
  或把 `ALIVE_STALE_SEC` 调小。
- **下次怎么避**：**维护前先停守护**（`sed -i '/guardian/d' /etc/crontabs/root` + 重启 cron），
  维护完再挂回去。

### P30 守护日志里的 `FIX` / `ALERT` 会进系统日志，但普通 `INFO` 不会

- **现象**：在 `logread` 里看不到守护的普通记录。
- **根因**：`guardian.sh` 的 `log()` 只在消息里含
  `FIX` / `ALERT` / `ERROR` / `WARN` 时才 `logger -t guardian -p daemon.warn`。
  普通 `INFO` 只写进文件。
- **解法**：要看完整流水，看 `$GUARDIAN_LOG` 文件，不看 `logread`。
- **下次怎么避**：排障时**两个都看** —— 文件是全量，`logread` 只是告警。

---

### P33 节点名 / 组名进 shell 的三种坑

- **`grep -q "name: $GROUP"` 是正则**：组名含 `[` / `*` / `.` 时误判「组缺失」，
  进而触发 hotupdate。改 `grep -F`。
- **`sed -i "s|^key=.*|key=$val|"` 的分隔符**：值里带 `|` 时 sed 报错，被 `2>/dev/null`
  吞掉、旧值残留（冷却 / 空闲计时会卡住）。改「临时文件 + 原子替换」，值按字面写入。
- **`enc()` 只转义空格**：节点名含 `&` / `?` / `#` 时 URL 被截断或落到错误路径，
  控制 API 返回 404，脚本记「被拒绝」而真实原因是 URL 构造错。

### P34 手写 DNS 报文：qname 必须逐标签编码

- **现象**：`qq_cdn_probe.py` 的 `dns` 段所有域名都是 `NODATA`，`probe` 段全部「解析失败」。
- **根因**：`bytes([len(host)] + [ord(c) for c in host])` 把整个域名编成**一个含点号的
  标签**。DNS wire format 里标签内不允许 `.`，递归服务器直接回 NXDOMAIN。
- **同文件还有两处**：`data[i] & 0xC0 == 0xC0` 的 `==` 优先级高于 `&`，实际只判断了
  最低位；单次 `recv(200)` 取不满 HTTP 状态行（响应头普遍超过 200 字节）。
- **怎么避**：手写协议报文时先找一份已知正确的包对照；运算符优先级不确定就加括号；
  读响应要循环到分隔符。

### P35 守卫脚本是逐仓复制的，复制时必须改目录白名单

- **现象**：`tools/check-secrets.py` 在本仓扫描 45 个文件，`mihomo/` 与 `cdn/` 的 11 个
  跟踪文件从未被扫过。
- **根因**：`SKIP_DIRS` 里带着上一站的 `"cdn"` / `"mihomo"`；复制脚本时只改了仓名。
- **同类**：`PLACEHOLDER` 命中后整行 `continue` —— 行内只要出现 `example.com` / `<...>`
  就把同一行的真值一起放过（7 个仓共有的问题）。
- **怎么避**：复制后先 `--all` 跑一遍，核对扫描文件数是否符合预期；
  占位符只豁免匹配片段本身，不要整行放行。

### P36 大流量守卫的存活检查必须用大流量探测 URL

- **现象**：`bulk-guard.sh` 把「公共-02」钉进 `📺 大流量`，但 `proof.ovh.net`
  4MB 三次都是 000；同一节点对 `gstatic.com/generate_204` 的延迟测试是 200/335ms。
- **根因**：`node_alive()` 只测 `ALIVE_URL`（gstatic 204），而大流量实际走
  `PROBE_URL`（`proof.ovh.net`）。公共节点可以「能出网」但到 OVH 的 TLS 握手 EOF /
  HTTP 502；mihomo 的 `/delay` 对后者返回 503 + message，原逻辑只看 HTTP 状态码。
- **解法**：新增 `node_bulk_alive()`，要求 `/delay?url=$PROBE_URL` 返回 HTTP 200
  **且响应体含 `"delay"`**；`pool_health()`、`pick_live_node()`、`handle_slow()`
  全部改用它。未钉住时也检查 URLTest 当前节点，不合格就先钉一个合格节点。
- **验证**：2026-10-23 实测 10 条公共节点里 3 条（02/03/06）只能过 gstatic；
  修复后守卫跳过它们、钉 `公共-08`，OVH 4MB 实测 1.9–2.2 MB/s。

### P37 钉住（fixed）的节点 ≠ 实际承流（now）的节点

- **现象**：2026-10-23 `bulk-guard.sh` 每轮体检都「健康」，但 Telegram /
  媒体下载停滞一整天不切机场。实况：`🆓 公共备用` 的 `fixed=公共-01`
  （OVH 探测通），`now=公共-09`（OVH Timeout）—— 流量全走死节点。
- **根因**：mihomo 的 `PUT /proxies/<组>` 只是「偏好」，被钉节点过不了核心
  gstatic 健康检查时 url-test 会自动漂走；url-test 选节点只看 gstatic 延迟，
  与能否跑大流量正交。守卫只盯 `fixed` 就盯错了对象。
- **解法**：`pool_health()` 改为以 `grp "$PUBLIC"`（now）为准；换钉候选要求
  gstatic + 大流量探测**双通**（`pick_live_node()` 同时调 `node_alive` 与
  `node_bulk_alive`），钉住后 sleep 3 再取 `now` 复核真的跟上，钉不住换下一个。
- **验证**：修复后手动实跑一轮，死节点在单轮内被换钉（日志出现
  「钉住生效」）；`--status` 的「公共池（钉住: …）」与控制 API 的 `now` 一致。

### P38 守卫的冷却必须大于 cron 周期

- **现象**：日志里 16:30→16:40、18:50→19:00、22:50→23:00 —— 每次切到机场
  10 分钟整就被切回公共池，机场停留名存实亡，用户从没见过它在机场。
- **根因**：`RETURN_COOLDOWN=600s` 恰好等于 `*/10` 的 cron 周期。切机场那轮
  的 `cooldown_until = 轮首时间戳 + 600`，下一轮 cron 的整秒时间戳 ≥ 到期点，
  「空闲 ≥300s」也满足（停滞连接 0 增量在守卫眼里就是空闲），必然回切。
- **解法**：冷却改为 1200s（脚本默认值 + `device.conf.example` 样例同步），
  注释写明「必须大于 cron 周期」。
- **验证**：切换后观察两轮 cron，机场停留 ≥ 20 分钟才出现「机场已空闲 N 分钟」。

### P39 「探测无效不判定」遇上死透的承流节点 = 永不切换

- **现象**：承流节点完全死透时，空闲探测（走全组下载 4MB）超时返回无效，
  日志写「本次不判定（下轮重试）」；可 `last_probe` 不推进，下一轮 cron 又
  距上次有效探测不足 2 小时，连探测都不跑 —— 18:30 / 18:40 两次无效后，
  下一次机会在 2 小时后。
- **根因**：`idle_probe()` 把「无效」当「没有信息」放过，而无效恰恰意味着
  「组路径能握手、不能承数据」—— 是最需要切换的信号。
- **解法**：`bad_probe` 计数（state 文件）连续 2 次无效即切机场，并推进
  `last_probe` 止血（不再每轮烧 4MB 重试）；有效探测清零计数。
- **验证**：`--status` 观察 `bad_probe` 键；把组钉到死节点后两轮内出现
  「空闲探测连续 2 次无效」的 FIX 行。

## 4. 还没写进来的坑

以下几条**知道存在但证据还不完整**，先记在这里，等复现后补完整：

- 某些订阅在 `DOMAIN-KEYWORD` 上用宽泛关键词（`google` / `cdn` 之类）造成的连带影响 ——
  审计器的「广告误伤」检测能看出来，但它**只检查广告组**，其他组的关键词误伤没覆盖。
- 闪存（overlay）写满后的表现与 `/tmp` 写满**不一样**（一个是 ENOSPC，一个是 OOM），
  本仓目前**没有**对 overlay 水位的守卫。

### P40 `nft list table <名>` 缺省查 ip 族，inet 表永远删不掉

- **现象**：`recover-now.sh` 第 2 节日志显示执行了，但 DNS 劫持表还在，内网依旧没网。
- **根因**：`DNS_HIJACK_TABLES` 写的是 `inet googleroute inet shellcrash ...` 的空格串，
  循环把每个词当独立表名；`nft list table googleroute` 不带 family 时默认 **ip** 族，
  而表是 **inet** 族，查不到也就不删。`nft delete table $t` 同理。
- **解法**：配置改成 `family:表名`（`inet:googleroute`），循环里拆开再 `nft list/delete table $fam $t`；
  默认值同步。凡是要操作自建表的地方都按 `inet <表名>` 写全。
- **验证**：`recover-now.sh check` 看 `nft list tables` 前后对比；真机删表后 DNS 回到直连。

### P41 BusyBox 的 `ip` 没有 `-brief`，错误被 `2>/dev/null` 吞掉后会误判 WAN

- **现象**：恢复脚本报「WAN 口没有地址」并执行 `ifup wan`，但面板上 WAN 明明有地址。
- **根因**：`ip -brief addr show` 是 iproute2 的选项，BusyBox 自带 `ip` 不支持；
  输出为空 + 错误被吞，`grep -q wan` 恒失败。
- **解法**：先探测 `ip -brief addr show >/dev/null 2>&1` 是否可用，不可用回退
  `ip -4 addr show`；或直接用 `ifstatus wan` / ubus。判断「有没有地址」不要依赖某个实现的输出格式。
- **验证**：在只有 BusyBox `ip` 的设备上跑一次恢复脚本的 `check` 模式，确认不再误报。

### P42 `/connections` 是连接累计值 —— 首见连接按「新值 − 0」计会把重启前的字节一次算清

- **现象**：`traffic-stats.sh` 首轮（或核心重启、状态文件丢失后）的某一分钟统计
  突然虚高，把下载会话开跑以来的字节一次性计入当日文件。
- **根因**：mihomo `/connections` 的 `upload` / `download` 是**连接累计值**，不是
  速率；状态里没有的连接 id 按「新值 − 0」算差值，等于把采样之前的历史全部记到
  这一轮头上。
- **解法**：首见连接只记「种子」（写进状态、不产差值），从下一次采样起才计增量；
  脚本头部「已知偏差」注明新连接首窗不计。
- **验证**：删掉 `$RUNTIME_DIR/traffic-stats.state` 后连跑两次采样，第一轮不产生
  差值（当日文件不新增行），第二轮起才有增量。

### P43 空池退化成直连 —— 探测域直连是通的，守卫看不出「池子已经空了」

- **现象**：2026-11-04 上午公共节点部署失败（路由器重启 + 回滚写入失败）后
  `yamls/proxies.yaml` 只剩 SUB-SYNC 块，`🆓 公共备用` 的成员只剩 `COMPATIBLE`，
  `📺 大流量` 仍钉在它上面 —— Telegram 走 `149.154.160.0/20` 直连超时，
  **近 4 小时没有任何自动动作**；`bulk-guard.sh` 日志里只有「空闲探测 1290 KB/s（健康）」。
- **根因**：两层都看不见空池。
  1. url-test 组没有真成员时 `now` 退回 `COMPATIBLE`（= 直连），而探测域
     `proof.ovh.net` **直连是通的**、速率也够 → `pool_health()` / `idle_probe()`
     判定「健康」；
  2. `机场 → 公共池` 的回切分支只查「冷却到 + 空闲够久」，不看池子里有没有节点，
     空池照切不误（日志里出现过「切回公共池（钉住「COMPATIBLE」）」）。
- **解法**：新增 `pool_real()`（成员剔除 `DIRECT` / `COMPATIBLE` / `REJECT` 等内置项）
  与 `api_ok()`（核心重启时 GET 会空，不能据此判空池）；池子空且 API 可用 → 立刻
  切机场；在机场时回切前必须 `pick_live_node_n 3` 找到双通节点，否则留在机场并
  每 6 小时告警一次。候选统一走 `pool_cands()`：只取池内真节点 + 吞吐缓存排序，
  避免把缓存里残留的 `COMPATIBLE` 拿来 `PUT`（控制 API 会拒绝并刷 ERROR）。
- **验证**：`BULK_TEST_POOL_EMPTY=1 … --dry-run` 分别验证「空池切机场」与
  「空池不回切」；真实场景下 15:40 那一轮把 `🆓 公共-03` 换成 `🆓 公共-07`
  （`FIX: … 改钉 …（钉住生效）`），随后 Telegram 两个 DC 段均 200。

### P44 门禁脚本用 `✓` / `✗` 打结论，GBK 控制台下把自己判成失败 【通用】

- **现象**：Windows 中文控制台（cp936）跑 `python -I tools/check-docs.py`，最后一行
  `print(f"✓ …")` 抛 `UnicodeEncodeError: 'gbk' codec can't encode character '\u2713'`，
  脚本以**退出码 1** 结束 —— 检查其实全过，门禁却报红。CI 是 UTF-8，看不到，能长期潜伏。
- **根因**：`✓` U+2713 / `✗` U+2717 / `⚠` U+26A0 不在 cp936 码表，`sys.stdout` 在这个环境里
  就是 `gbk`；`python -I` 会把 `PYTHONIOENCODING` / `PYTHONUTF8` 一起忽略，所以「设个环境变量」
  不是解法 —— 必须改脚本。
- **解法**：结论行只用 ASCII（`[OK]` / `[FAIL]` / `[!]`）；入口再加
  `if hasattr(sys.stdout, "reconfigure"): sys.stdout.reconfigure(errors="replace")`，
  非 GBK 字符降级成 `?` 而不是抛异常。同一问题首次记录见 ModelBus 仓「踩坑总汇」第 36 节（跨仓引用，非本仓路径）。
- **验证**：`python -I tools/check-docs.py` → `[OK] …`、退出码 0；反证：把 `✓` 改回原样，
  同一命令退出码 1 并抛 `UnicodeEncodeError`。

### P45 状态文件缺键取 0 当兜底，`now − key` 会等于整个 epoch

- **现象**：`bulk-guard.sh` 日志出现「机场已空闲 29898910 分钟」（≈57 年），
  之后每轮 cron 都在机场与公共池之间来回切，约 20 分钟抖动一次。
- **根因**：`LAST_MOVING=$(state_get last_moving)` 之后紧接
  `LAST_MOVING=${LAST_MOVING:-0}` —— 状态文件里没有这个键（新装、换过 `BULK_STATE`、
  `/tmp` 重启被清）时取到 0，`NOW_TS - LAST_MOVING` 就等于自 1970 年以来的秒数。
  回切判据 `-ge $IDLE_SWITCH` 与「清已试」判据 `-gt $IDLE_SWITCH` 同时被击穿，
  于是每轮都判「空闲够久」。
- **解法**：缺键 / 为 0 / 非数字一律**回填当前时间** ——
  `case "$LAST_MOVING" in ''|0|*[!0-9]*) LAST_MOVING=$NOW_TS ;; esac`
  （两处：状态读取段、回切判定段）。同时让 `switch_airport()` 除写 `cooldown_until`
  外也写 `state_set last_moving "$NOW_TS"` —— 切到机场那一刻就是「刚活动」，
  否则回切空闲仍从上一个会话的时间戳起算。
- **下次怎么避**：任何「时间戳相减」的判据，缺省值都不能是 0（0 是 1970 年）；
  状态文件里的每个时间键都要有「缺失即当前时间」的兜底，
  并且**所有改变状态的路径**都要写一遍那个键，别只在一条分支里写。
- **验证**：把 `BULK_STATE` 指向一个不存在的临时文件（模拟缺键）跑 `--dry-run`，
  不应出现五位数空闲分钟、也不应触发回切；`--status` 的「回切:」一行门槛应与
  `device.conf` 里配的停留/空闲秒数一致。阈值贴边导致的抖动另见 CHANGELOG 2026-11-06。

### P46 升级后验收写死 `CrashCore.raw`，upx 内核设备静默漏掉 `-t` 校验 【通用】

- **现象**：ShellCrash 1.9.5beta3 起提供 upx 压缩内核（`CrashCore.upx`）。设备 2026-11-10
  实况只有 `/etc/ShellCrash/CrashCore.upx` + `/tmp/ShellCrash/CrashCore` 软链，
  **没有** `CrashCore.raw`。`openwrt/post-sc-update.sh` 验收段原先
  `if [ -x "$CORE_BIN" ]; then "$CORE_BIN" -t …; fi`，`CORE_BIN` 默认就是 `.raw` →
  条件不成立就**静默跳过** `-t`，日志照样写「===== 5. 验收 =====」和分组数 / 规则数，
  配置错了也看不出来（设备 `/root/post-sc-update.log` 尾段正是「分组数：30 规则数：0」无 `-t` 行）。
  ShellcrashRules 仓的 `config/post-sc-update.sh:96` 更直接：写死 `.raw` 会报 `not found`。
- **根因**：内核文件名随版本分支变 —— 精简 / 标准版是 `CrashCore.upx`，旧版是
  `CrashCore.raw`，运行态统一是 `$RUNTIME_DIR/CrashCore` 软链。把 `-t` 挂在某个具体
  文件名上，另外两种布局就漏校验；而「跳过」分支不留日志时，巡检会假绿。
- **解法**：验收段改成 `CORE_BIN` 显式覆盖优先（`-x` 命中即用），否则按
  **`CrashCore.upx` → `CrashCore.raw` → `$RUNTIME_DIR/CrashCore`** 顺序探测第一个 `[ -x ]`
  的内核，找到 `log "配置校验内核：$CHECK_BIN"` 再跑 `-t`；三者都不在时显式 log
  `!! 未找到可执行内核…跳过 -t 校验`。`:175/:189` 的 `pidof "$CORE_PROC"` 启动链路一行不动。
- **下次怎么避**：要 exec 内核做校验 / 取版本，路径一律走「候选列表 + `-x` 探测」；
  验收段的跳过分支必须留日志。同一根因在 ShellcrashRules 仓 `docs/PITFALLS.md` §44 也有记录（跨仓，路径按本地 clone 调整）。
- **验证**：五场景 fixture（upx+raw→选 upx / 仅 raw→兼容旧环境 / 仅软链→回退 / 全无→
  显式告警 / `CORE_BIN` 显式覆盖→不回退）全过；设备实况探测命中
  `/etc/ShellCrash/CrashCore.upx`（v1.19.28）；`sh -n` rc=0、仓内与设备 md5 均
  `8e908bdcb3773b3af5c97a18f476a08e`（226 行）。

### P47 LuCI 的内存占用百分比把 page cache 算成「已用」，看着 86% 其实还有 30MB 真余量 【通用】

- **现象**：233MB 的 MT7981 设备，LuCI 概览页内存常年 80%+（实测 86%），用户以为
  「内存快撑爆了」。同一时刻 `free -m` 是 used 137MB / free 33MB / buff-cache 68MB，
  `MemAvailable` 只有 22–33MB —— 两个数字讲的其实是两件事，但界面上只显示一个。
- **根因**：LuCI 状态页算的是 `(MemTotal − MemFree) / MemTotal`，而 Linux 的
  `MemFree` **不含** page cache / buffer（这台设备 61–70MB）。缓存是可回收的，
  却被算进「已用」；真正的宽松度只看 `MemAvailable`（它已经把可回收缓存加回来了）。
  另一半容易误判的是 mihomo：`VmRSS 73060kB / VmHWM 73096kB` —— 峰值≈当前值，
  **不是泄漏**，而且这已经是 `GOMEMLIMIT=64MiB`（`/etc/ShellCrash/configs/command.env:4`）
  压过的结果，再往下压就是拿 GC 抖动换几个 MB，不划算。
- **解法**：给这种设备加 zram 压缩 swap，用 CPU 换内存，把「瞬时峰值直接触发 OOM killer
  杀核心」变成「先压缩换出」。`openwrt/setup-zram.sh` 一条命令搞定（幂等，可重复跑）：
  `apk add kmod-zram zram-swap` → `uci set system.@system[0].zram_size_mb` / `zram_comp_algo`
  → `/etc/sysctl.d/99-zram.conf` 写 `vm.swappiness = 80` → 核验 `/proc/swaps`。
  同时把 `guardian.sh` 的「可用内存仅 …MB」判据改成 `MemAvailable + SwapFree/2`
  —— zram 的 `disksize` 是**逻辑容量**，压缩比 2–3x，折半才不虚高。
- **下次怎么避**：`free` 的 used / LuCI 的百分比**都不能当内存压力指标**，只看
  `MemAvailable`（有 swap 时再看 `SwapFree`）；怀疑进程泄漏，看 `VmHWM vs VmRSS`
  而不是看绝对值 —— 峰值≈当前值说明只是「一直在用这么多」。
- **验证**（设备 root@10.0.0.1，OpenWrt 25.12.6 / 内核 6.12.112 / 用 `apk` 不是 `opkg`）：
  `apk add kmod-zram zram-swap` 装到 `kmod-zram-6.12.112-r1`（与内核精确匹配，
  不匹配会直接 insmod 失败），post-install 立刻建出 `/dev/zram0` 118780KB 并 swapon；
  `/etc/rc.d/S15zram` 自启已生效；装完 `SwapFree 118780 / MemAvailable 29MB`，
  `mm_stat` 从 `4096 62 20480 …` 开始（说明已初始化、尚未真正换出）；
  `sh -n setup-zram.sh` rc=0，`--status` / `--dry-run` 输出符合预期且**不会对已在
  swap 里的设备做 `swapoff`**（那会把已换出的页全拉回内存，瞬间 OOM）。

### P48 OpenWrt 25.12 的 apk 升级四连坑：copy-up 涨空间、缓存落 overlay、`--exclude` 静默失败、进程还在旧 inode 【通用】

- **现象**：`apk upgrade --simulate` 报 28.2 MiB / 221 包全量升级，而 `/overlay` 只剩
  19.6MB；升级完 `apk list -u` 已经是 0 条，dnsmasq / hostapd 的行为却没变；
  设备上 `tar czf … --exclude=…` 退出码 0 却只产出 0 字节文件；
  `nohup`、`diff` 在 busybox 里都不存在。
- **根因**（四个独立坑）：
  1. **overlayfs 上升级 = copy-up**：squashfs 下层的旧文件被上层新文件覆盖后，旧字节
     仍在只读层占着、**不会释放**，所以每批升级都是净增；可用空间要按
     「下载缓存 + 解压后新文件」双份估算。
  2. **apk-tools 3 的包缓存不在 `/tmp`**，在 `/overlay/modern-pkg-cache`
     （`apk/` 目录 + `*.pool` 单包文件）；`apk --help` 里只有 `cache` 子命令，
     没有 `--cache-dir` 顶层选项。
  3. **busybox tar 不认 `--exclude`**，只支持 `-X FILE` 排除列表；带了 `--exclude`
     会报错，若在脚本里 `2>/dev/null` 就变成静默产 0 字节。
  4. **apk 只替换磁盘文件、不重启服务**：运行中的进程仍映射被 unlink 的旧 inode，
     `readlink /proc/<pid>/exe` 显示 `(deleted)`；`wifi reload` 只重读配置，
     **不重启 hostapd 进程**。
- **解法**：
  - 腾空间优先级：`/root` 里旧的 `CrashCore.upx.bak-*`（9.8MB）先 `mv /tmp/`
    （可回滚，别直接删）→ 清 `/overlay/modern-pkg-cache/apk/*` 与 `*.pool`。
  - 分批：基础设施小包（16 个，约 2MB）→ LuCI 全家（26 个，体积最大）→ WiFi 栈
    （2 个，断无线几秒），每批后清缓存再下一批。
  - 备份用 `tar czf out.tgz /etc` 全量（含核心 14.3MB，压缩后 16MB），要排除时写
    `-X excludefile`。
  - `.apk-new`：本地改过的配置被新包标注时，先 `cmp -s` 确认差异（设备没有 `diff`）、
    存档原件到 `/tmp/pkgup/apknew/`、保留本机版本、再删 `.apk-new`。
  - 服务生效：`/etc/init.d/dnsmasq restart`、`/etc/init.d/uhttpd restart`、
    `/etc/init.d/wpad restart`；用 `readlink /proc/<pid>/exe` 里有没有 `(deleted)` 判定。
- **下次怎么避**：升级前先算三笔账 —— `/overlay` 可用、下载大小、解压后增量；
  `apk list -u | grep -c '^kmod'` 为 0 才敢说「不动内核」；升级后必须查一遍
  `readlink /proc/*/exe` 的 `(deleted)`，否则「版本号变了但行为没变」会反复误判。
  远程跑升级脚本别用 `nohup`（不存在），要么前台跑（别断网），要么 `ssh … "sh s.sh"` 一条命令跑完。
- **验证**（设备 root@10.0.0.1，OpenWrt 25.12.6 / apk-tools 3.0.5）：44 包全升后
  `apk list -u` = 0、已装 221 不变；dnsmasq pid 4425→8157、uhttpd 7669、
  hostapd 2047→8759 均无 `(deleted)`；DNS 双栈、代理 204/200/200、无线 5 客户端回连、
  `/overlay` 28.5MB 可用。

### P49 策略组名写死在脚本默认值里，设备值随源码外泄 【通用】

- **现象**：`traffic-stats.sh --summary` 不配 `STATS_AIRPORT_GROUPS` 也能出分账，因为默认值是
  「🚀 节点选择|🤖 干净出口|🤖 AI接口|…」这串**真实组名**；公开仓因此把这台设备的分组结构带了出去。
- **根因**：默认值当兜底最省事，但组名属于设备真值（AGENTS §3「设备值必须外置」），
  且 emoji 组名在 GBK 控制台与 awk 里还有 P21 的老问题。
- **解法**：默认值置空；awk 里补 `air != "" &&` / `dir != "" &&` 前置判断
  （**空 ERE 匹配所有行**，会把全部流量算成机场出口，比不分账更糟），未配置时只打总量 +
  一行「未配置 … 不分账」提示。
- **下次怎么避**：脚本默认值只允许出现「设备无关」常量；凡是要填组名 / 节点名 / 域名的键，
  默认必须是空串，缺了就报「未配置」而不是猜一个。
- **验证**：未配置时 `sh openwrt/traffic-stats.sh --summary` 打总量 + 提示；配上
  `STATS_AIRPORT_GROUPS` 后分账行恢复。

### P50 三个脚本各自复制同一段函数，改一处漏两处 【通用】

- **现象**：secret 读取、`enc()`、`json_esc()`、`put()`、日志截尾在 guardian / bulk-guard /
  traffic-stats 里各有一份，引号风格、有没有 `tr -d '\r'`、临时文件名全不一样 ——
  CRLF 的 `ShellCrash.cfg` 只在其中一份里被处理。
- **根因**：busybox ash 没有「公共库」的部署惯例，复制粘贴最快；复制完就各走各的。
- **解法**：**不引公共文件**（部署面变大、还可能被 ShellCrash 更新冲掉），改用
  「标记块 + 门禁」：`# >>> shared:<id> >>>` / `# <<< shared:<id> <<<` 包住副本，
  `tools/check-shell-shared-blocks.py` 剥掉行首行尾空白与空行后逐字比对，不一致 exit 1，CI 里跑。
- **下次怎么避**：任何跨脚本复制超过 5 行的逻辑都加标记块；改一处必须同步改所有副本并过门禁。
- **验证**：`python tools/check-shell-shared-blocks.py` →
  `[shared] OK 6 个块 / 3 个脚本，全部一致`，exit 0（2026-11-14 加 `api-field` 后实测；
  块数会随收敛继续增加，以门禁输出为准）。

### P51 `/tmp` 清理白名单用 `case "$f" in /tmp/*)` 判前缀，能穿出去也能删空整个 tmpfs 【通用】

- **现象**：`TMPFS_CLEAN_FILES` 里写 `/tmp/../etc/passwd` 会通过前缀判断；
  写 `/tmp` 或 `/tmp/` 时 `rm -rf` 会把整个 tmpfs 抹掉（`/tmp/` 本身就能匹配 `/tmp/*`）。
- **根因**：`case` 通配只做前缀匹配，不规范化路径、也不排除「根目录自身」。
- **解法**：白名单改 `/tmp/?*`，并在前面加两道闸：`*..*` 直接拒绝、
  `/tmp|/tmp/` 直接拒绝（跳过 + 记日志，不静默）。
- **下次怎么避**：任何 `rm -rf` 的路径白名单都要同时挡 `..` 与「根目录自身」两种输入。
- **验证**：本地 fixture 里塞 `/tmp/../x`、`/tmp`、`/tmp/` 三个条目，日志出现拒绝行、
  `/tmp` 内容不变。

### P52 端口就绪判断用 `grep ":$PORT"`，789 命中 7892 【通用】

- **现象**：`post-sc-update.sh` 的 `core_up()` 原来用 `netstat -lntp | grep -q ":$MIXED_PORT"`，
  只有 789 在听时也判 7892 已就绪，于是内核没起来照样往下跑。
- **根因**：`grep` 默认 BRE 子串匹配，`:789` 是 `:7892` 的前缀。
- **解法**：`case` 先挡非数字，再用 `grep -qE "[:.]$PORT[[:space:]]"`
  （`[:.]` 兼容 `127.0.0.1:7892` 与 `[::]:7892`，`[[:space:]]` 挡住数字后缀）。
- **下次怎么避**：端口 / PID / 版本号这类「数字前缀敏感」的判断一律加右边界；能加 `-F` 的加 `-F`。
- **验证**：`MIXED_PORT=789` 在只有 7892 监听时 `core_up` 返回 1。

### P53 日志截尾 / 状态写入用固定临时名，两个实例互踩 【通用】

- **现象**：`bulk-guard.sh` 的日志截尾 `tail -60 "$LOG" > "$LOG.tmp" && mv` 在
  `acquire_lock` **之前**执行，同一秒两个 cron 实例会写同一个 `$LOG.tmp`，
  结果是截出半份日志、或 `mv` 拿到别人写的内容；`speed_set` 的 `$SPEED.tmp` 同理。
- **根因**：临时文件名没带 PID，且截尾动作放在了锁外面。
- **解法**：临时名统一带 `$$`（`"$LOG.tmp.$$"` / `"$SPEED.tmp.$$"`），失败时
  `rm -f` 自己的临时文件；截尾抽成共享块 `log_trim`，阈值与行数参数化。
- **下次怎么避**：任何「写临时文件再 mv」都要带 `$$`；有副作用的动作先拿锁。
- **验证**：连跑两次 `log_trim`，日志不出现半行、不残留 `*.tmp.*`。

### P54 机器可读状态口没有年龄判定、也不是原子写，陈旧或半截状态被当成现状 【通用】

- **现象**：`/tmp/router-health/health.json` 里是三小时前的数据，消费方照读不误；
  写方用 `{ ... } > "$X"` 直接重定向（先 truncate 再写），读方可能读到半截文件；
  状态文件里没有 `ts` 时，「读不到」和「等于 0」分不开。
- **根因**：状态文件是「最后写入者赢」，不带时间戳就没有新鲜度语义；重定向不是原子替换。
- **解法**：写方一律 `> "$X.tmp.$$" && mv -f "$X.tmp.$$" "$X"`（同目录，tmpfs 上 mv 是原子的）；
  读方必须取 `ts`/`"epoch"` 算 `age_s`，并在自检里按 `CROSS_STATE_STALE_SEC`
  （默认 1800 秒）报「陈旧」、文件不存在报「缺失」、有文件没 `ts` 也要单独说一句。
- **下次怎么避**：任何「状态文件」都必须自带 `ts`；写方 tmp+mv；读方一律输出 `age_s`
  并对陈旧告警。JSON 里缺值一律 `null` + `present:false`，不许写 0。
- **验证**：fixture 里把 `ts` 改成 4000 秒前 →
  `[warn] 状态口陈旧: guardian.state 已 4072s 未更新（阈值 1800s，<全路径>）`；
  删掉文件 → `[warn] 状态口缺失: …（<全路径>）—— 生产方没跑过，或路径配错`；
  `--json` 里对应 `present: false, age_s: null, fields: null`。

### P55 同一个指标在两个脚本里各有一套默认阈值，自检说 OK 而守护已在告警 【通用】

- **现象**：`guardian.sh` 在 `/tmp` ≥ `80%`、宽松内存 < `30MB` 时动手；
  `ops-status.sh` 却按 `85%` / `40MB` 报 `[ok]`——同一时刻一边删临时文件、一边说没事。
- **根因**：两个脚本各自写 `${TMPFS_WARN_PCT:-…}`，复制时只改了一处；键名相同、语义漂移。
- **解法**：默认值同源（都是 `80` / `30`），两边都加注释指向对方；要改就同一轮一起改。
- **下次怎么避**：同名键的默认值只能有一处正本，另一处写明「必须与 `xxx.sh` 一致」；
  改阈值时 `grep` 全仓同名键。
- **验证**：`/tmp` 用到 81% 时，`sh ops-status.sh --self-check` 报 `[warn]`，
  与同轮 `guardian.log` 里的水位告警一致。

### P56 配置变量没加引号被当成 glob 展开，查的表名变成当前目录里的文件名 【通用】

- **现象**：`NFT_TABLES` 里写了含 `*` / `?` / `[` 的表名（清单型变量都可能），
  `$NFT list table inet $t` 里的 `$t` 被 shell 当通配符展开成当前目录下的文件名，
  `nft` 收到完全无关的表名 → 判「表缺失」→ 每轮都去补载。
- **根因**：裸变量展开同时做分词与路径名展开（glob），值是「配置里来的」也不例外。
- **解法**：`inet "$t"`；`for x in $LIST` 只让 `$LIST` 分词，循环体里 `$x` 一律加引号。
- **下次怎么避**：凡是值来自配置文件的变量，出现在命令参数位置一律加双引号；
  唯一允许裸写的位置是 `for ... in $LIST` 的分词点。
- **验证**：fixture 里 `NFT_TABLES="qui*"` 且当前目录有 `quicguard.nft`，
  加引号后 `--status` 显示查的是字面表名 `qui*`，不再报「缺失且 .nft 不存在」。

### P57 两个仓的守护写同一个状态文件名，后写者覆盖前写者 【通用】

- **现象**：设备上同时装 `AX3000TOpenwrt` 的 `guardian` 与本仓 `openwrt/guardian.sh` 时，
  `ops-status.sh` 报的 `fixes` / `errors` / `warns` 每五分钟在两个值之间来回跳，
  `age_s` 永远很小；查日志才发现两条 cron 都在跑。
- **根因**：两版都把「每轮原子写状态」落在 `$RUNTIME_DIR/guardian.state`。文件名相同，
  后跑的覆盖先跑的；下游把「刚被另一版覆盖」误读成「守护很健康、刚更新过」。
- **解法**：**文件名分开**（本仓写 `ops-guardian.state`，AX 版保持 `guardian.state`），
  消费方 `ops-status.sh` 按 `ops-guardian.state` → `guardian.state` 顺序探测；
  键名仍完全对齐，消费方不必知道是哪一版写的。
- **下次怎么避**：跨仓共享的是**格式与键名，不是路径**。两个实现要共存时，
  先定「谁是这段路径的唯一写者」，另一个必须换名。
- **验证**：本机 `printf 'ts=%s\nstate=probe\n' "$(date +%s)" > /tmp/ShellCrash/ops-guardian.state`
  后 `ops-status.sh --json` 的 `cross_repo.guardian_state.path` 指向 `ops-guardian.state`
  （`fields` 里是刚写的键）；删掉文件后回退到 `guardian.state`，两条路径都实测成立。
