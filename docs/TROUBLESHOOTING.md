# 排错手册

> **一句话**：按**现象**查 —— 每条给「排查步骤」与「原因 / 解法」，
> 每一步都能落到本仓某个脚本上；是全仓排障流程的**正本**。

**用法**：先按现象找到对应小节，照着「排查步骤」跑；
「原因 / 解法」那一段是**结论**，别跳过步骤直接照抄结论。

**通用前提**：设备侧脚本在路由器上跑，控制面工具在你的电脑上跑。
两边都要能连上：控制面工具需要 mihomo 控制 API（默认 `127.0.0.1:9999`），
凭据走环境变量 `MIHOMO_SECRET`（见 [SECRETS.md](SECRETS.md)）。

**下文的 `<组名>`、`<节点名>` 都是占位符** —— 换成你自己订阅里的名字。

---

## 1. 连上了 WiFi 但没网

> 症状：WiFi 关联成功、有 IP、但什么都打不开；或者一会儿好一会儿坏。

### 排查步骤

1. **先分清是「内网就断」还是「只有境外断」**。在设备上：

   ```sh
   nslookup www.baidu.com 127.0.0.1
   ```

   解析失败 → 内网 DNS 链路断了，往第 3 步走。
   解析成功但浏览器打不开 → 继续第 2 步。

2. **看核心在不在、端口在不在**：

   ```sh
   pidof CrashCore
   netstat -lntp | grep -E ':7892|:9999|:1053'
   ```

   `CrashCore` 进程不在、或 7892/1053 没监听 → 核心没起来，往 [第 2 节](#2-代理核心假死) 走。

3. **看 DNS 劫持表在不在**（含 DNS 劫持的表若指向一个没监听的端口，内网解析全废）：

   ```sh
   nft list tables
   ```

   缺表 → 守护会补载；先看守护日志（`$GUARDIAN_LOG`）有没有 `FIX: nft 表 inet ... 已从 ... 重载`。

4. **看 `/var` 下的运行时目录**（`/var` 是指向 tmpfs 的软链，目录没了 dnsmasq 起不来）：

   ```sh
   ls -d /var/etc /var/lib /var/run /var/lock
   ```

   缺哪个就 `mkdir -p` 哪个。

5. **看防火墙是不是半加载状态**：

   ```sh
   /etc/init.d/firewall restart
   ip -brief addr show | grep wan
   ip route show default
   ```

   WAN 没地址或没默认路由 → `ifup wan`。

6. **以上都正常还是不通** → 跑**只诊断不改动**的恢复脚本拿全量快照：

   ```sh
   sh openwrt/recover-now.sh check
   ```

   它会打印 uptime、`df -h /tmp /overlay`、核心与端口状态、`nft list tables`、内网解析结果。

### 原因 / 解法

最常见的三个成因，**按顺序**修：

1. **`fake_ip_filter` 里有空行** → mihomo DNS 异常不自愈 → 内网解析全挂。
   解法：`sh openwrt/recover-now.sh`（§1 会备份并清洗该文件）。
2. **含 DNS 劫持的 nft 表先于核心加载** → 内网 DNS 指向没人监听的端口。
   解法：`openwrt/rc.local` 已按「等 DNS 端口就绪再加载」处理；
   手工加表时也要照这个顺序。
3. **`start.sh` 把 fw4 留在半加载状态** → 路由看着正常但转发不通。
   解法：`recover-now.sh` §4.1 固定跑一次 `firewall restart`。

详见 [PITFALLS.md](PITFALLS.md) 的 P2 / P3 / P5 / P9。

---

## 2. 代理核心假死

> 症状：核心进程还在，但 API 没响应（假死）；或者核心进程直接没了。

### 排查步骤

1. **先确认是「假死」还是「真没」**：

   ```sh
   pidof CrashCore
   SECRET=$(sed -n 's/^secret=//p' /etc/ShellCrash/configs/ShellCrash.cfg | head -1)
   curl -s -m 5 -H "Authorization: Bearer $SECRET" http://127.0.0.1:9999/version
   ```

   进程在但 API 没响应 → **假死**（可能正在热重载）。
   进程没了 → 看第 2 步。

2. **看守护有没有处理过**：

   ```sh
   tail -50 "$GUARDIAN_LOG"      # 默认 /tmp/ShellCrash/guardian.log
   logread | grep guardian
   ```

   看到 `ALERT: CrashCore 进程不存在（可能是 OOM 被杀），用 start.sh 拉起`
   → 守护已经处理过，看紧随其后的 `FIX:` 或 `ERROR:`。

3. **看是不是 OOM**：设备上 `dmesg | tail`（tmpfs，重启即丢），
   或看 `/proc/meminfo` 的 `MemAvailable` 与 `df -k /tmp`。

4. **手动拉起**（守护判定为「人为停止」时不会自动拉，见 [第 9 节](#9-守护进程误判)）：

   ```sh
   sh /etc/ShellCrash/start.sh start
   ```

   等 10–12 秒再看 `netstat -lntp | grep 7892`。

5. **起来了但立刻又挂** → 多半是配置校验失败被回退：

   ```sh
   ls -l /tmp/ShellCrash/error.yaml
   ```

   有 `error.yaml` = 配置校验失败过，核心已回退基础配置（自定义组与规则全丢）。
   解法见本节末尾的「原因 / 解法」。

### 原因 / 解法

- **OOM 被杀**：`/tmp` 是内存盘，写满就等于占光内存。
  `openwrt/guardian.sh` §6 会在 `/tmp` ≥ 80% 时清理白名单里的临时大文件；
  自己产生的大文件要登记进 `TMPFS_CLEAN_FILES`。
- **配置校验失败被静默回退**：`guardian.sh` §5 会检查运行态 `config.yaml` 里
  还有没有兜底组，没有就限频跑 `task.sh hotupdate` 重生成。
- **守护不拉起是设计**：进程不在、且最近 `ALIVE_STALE_SEC`（默认 1800 秒）
  没有存活记录 → 判定为你自己停的，**刻意不拉**（免得妨碍维护）。

---

## 3. 策略组被改坏

> 症状：组的出口跑到了不该跑的节点上。

### 排查步骤

1. **先看这个组现在选的是什么**：

   ```sh
   SECRET=$(sed -n 's/^secret=//p' /etc/ShellCrash/configs/ShellCrash.cfg | head -1)
   curl -s -H "Authorization: Bearer $SECRET" \
     "http://127.0.0.1:9999/proxies/<组名>" | grep -o '"now":"[^"]*"'
   ```

   或者用控制面工具（更方便）：

   ```sh
   MIHOMO_SECRET=xxx python3 mihomo/mihomo_api.py proxies "<组名>"
   ```

2. **看真实出口**（组可能还套着「手动切换」这一层）：

   ```sh
   MIHOMO_SECRET=xxx python3 mihomo/mihomo_api.py proxies
   ```

   `mihomo/mihomo_api.py proxies` 会打印每个组的 `type` / `now` / `udp`。
   要看完整链路（组 → 组 → 节点），用 `mihomo/rule_audit.py` 生成的报告 §2
   「策略组状态」表。

3. **看守护是否动过手**：

   ```sh
   grep -E 'FIX|ERROR' "$GUARDIAN_LOG" | tail -20
   ```

   典型记录：`FIX: <组名> 从「X」(实际出口「Y」) 复原为「Z」（该出口不可信）`。

4. **确认配置项配全了**：守护的每项自愈都要**好几个键同时非空**才生效
   （见 [ARCHITECTURE.md](ARCHITECTURE.md) §3.5 的键表）。
   例如出口健康守卫要 `POOL_GROUP` **和** `POOL_FALLBACK_GROUP` 都配了。

5. **想手工切回去**：

   ```sh
   curl -s -X PUT -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' \
     -d "{\"name\":\"<目标节点或组>\"}" \
     "http://127.0.0.1:9999/proxies/<组名>"
   ```

### 原因 / 解法

- **「实际出口」和「组的选择」不是一回事**：组可能指向另一个组，
  真正出去的节点在链子末端。`guardian.sh` 的 `eff_node()` 会顺着
  `MANUAL_GROUP` 解析出真实出口再判定。
- **守护只在出口命中坏节点通配时才复位**（`AI_BAD_NODES` / `POOL_BLOCKED_NODES`，
  `|` 分隔的 shell 通配）。通配没配 → **永远不判坏** → 什么都不做。
- **干净出口劣化时会轮换候选，但绝不降级到不可信节点**：
  所有候选都劣化时保持原状并报 `ALERT` ——
  因为目标站可能按地区拒绝服务。

---

## 4. 规则不生效

> 症状：规则配了，但流量没走那条。

### 排查步骤

1. **先确认规则到底生成了没有** —— 运行态配置在 tmpfs 上：

   ```sh
   grep -n "你的规则关键字" /tmp/ShellCrash/config.yaml
   ```

2. **看运行态有没有被回退**：

   ```sh
   ls -l /tmp/ShellCrash/error.yaml
   ```

   有 = 配置校验失败过，核心回退到了基础配置（自定义规则全丢）。
   这时**改规则是没用的**，先修配置错误。

3. **看规则在列表里的位置** —— 靠后的规则可能被靠前的宽泛规则遮蔽：

   ```sh
   MIHOMO_SECRET=xxx python3 mihomo/mihomo_api.py rulestats
   ```

4. **要精确答案就跑审计**（离线读 `config.yaml` + `proxies.json`）：

   ```sh
   python3 mihomo/rule_audit.py <config.yaml> <proxies.json> <lists目录> REPORT.md
   ```

   报告里看「§3 顺序与遮蔽（核心）」：
   - **生效目标 != 声明目标** = 顺序导致的实际改道；
   - **严重**（一边直连/拦截、一边代理）= 优先处理这些。

5. **看某条规则实际命中了什么**（运行态证据）：

   ```sh
   MIHOMO_SECRET=xxx python3 mihomo/mihomo_api.py conns
   ```

   输出里有 `rule=`（命中的规则类型）、`payload=`（命中的规则内容）、`chains=`（走的组链）。

6. **要抓某个域名到底走了哪条规则**：

   ```sh
   MIHOMO_SECRET=xxx python3 cdn/qq_rule_probe.py <域名>
   ```

### 原因 / 解法

- **先匹配先赢**：靠前的宽泛规则遮蔽靠后的具体规则 ——
  这是「声明 ≠ 生效」的根因，见 [PITFALLS.md](PITFALLS.md) P13。
  解法：把具体规则**移到**宽泛规则**之前**，然后重跑审计看「严重改道」条数。
- **`*.X` 与 `+.X` 不等价**：`*.X` 只匹配单标签子域，`+.X` 才匹配多层。
  审计器的模拟器**看不出**这个差别（它把两种前缀都剥掉），要回配置里核。
- **审计结论是方向性的**：审计用文本 geosite 模拟 `RULE-SET,cn`，
  而运行态用编译好的 `cn.mrs`，两者可能不同步。

---

## 5. 某个域名走了错误的路

### 排查步骤

1. **先看这个域名现在解析到什么**：

   ```sh
   MIHOMO_SECRET=xxx python3 mihomo/mihomo_api.py dns <域名>
   ```

2. **看它落在 cn 规则集内还是外**（决定 DNS 走国内还是境外）：

   ```sh
   MIHOMO_SECRET=xxx python3 cdn/qq_domain_classify.py <域名>
   ```

   输出 `国内DNS` / `境外DNS` / `明文DNS` 与判定。
   这个工具会**临时**把日志级别调到 `debug`，跑完改回 `info`。

3. **换个角度交叉验证**（看路由器**新产生**的 DNS 上游连接）：

   ```sh
   MIHOMO_SECRET=xxx python3 cdn/qq_dns_path.py <域名>
   ```

4. **看它命中了哪条规则**：

   ```sh
   MIHOMO_SECRET=xxx python3 cdn/qq_rule_probe.py <域名>
   ```

5. **看当前有没有连接、走的哪条链**：

   ```sh
   MIHOMO_SECRET=xxx python3 mihomo/mihomo_api.py conns
   ```

### 原因 / 解法

三条通道**分开测**才站得住结论：

| 测到的东西 | 工具 | 说明 |
|---|---|---|
| DNS 走哪条通道 | `qq_domain_classify.py` / `qq_dns_path.py` | 前者看日志里的上游选择，后者看新产生的上游连接 |
| 命中了哪条规则 | `qq_rule_probe.py` / `mihomo_api.py conns` | 前者边抓日志边发请求，后者看连接快照 |
| 规则顺序对不对 | `rule_audit.py` | 离线算「声明 vs 实际生效」 |

注意 `qq_dns_path.py` 的一个**已知限制**：如果 DNS 结果**命中缓存**，
就不会产生新的上游连接，输出会是「无新增 DNS 上游连接(可能命中缓存)」。
这时改用 `qq_domain_classify.py`（看日志）交叉验证。

---

## 6. CDN 连不上

> 症状：图片、头像之类加载不出来。

### 排查步骤

1. **把 DNS / TCP / TLS / HTTP 四段分开计时**：

   ```sh
   python3 cdn/qq_cdn_probe.py all
   ```

   输出形如 `tcp=0.01s tls=0.12s http=0.30s HTTP/1.1 200`。
   哪一段是空 / 是 `FAIL`，问题就在哪一段。

2. **只看解析**（不同 DNS 给出不同结果 = 有污染或分线路）：

   ```sh
   python3 cdn/qq_cdn_probe.py dns
   ```

3. **看这个域名在 cn 规则集内还是外**（走错通道是 CDN 打不开的头号原因）：

   ```sh
   MIHOMO_SECRET=xxx python3 cdn/qq_domain_classify.py <域名>
   ```

4. **看它命中了哪条规则**：

   ```sh
   MIHOMO_SECRET=xxx python3 cdn/qq_rule_probe.py <域名>
   ```

### 原因 / 解法

- **DNS 走了境外 DoH**：cdn 域名被解析到境外解析器，
  拿到的 IP 不对 → 连不上。解法是让该域名落进 cn 规则集（改**源**规则，不改运行态产物）。
- **TCP / TLS 卡住**：说明 IP 路由或握手有问题，不是规则问题。
- **HTTP 慢但成功**：多半是 QUIC 相关，见下一节。

> `qq_cdn_probe.py` 的 `probe` 段解析时**硬编码**用某一个公共 DNS ——
> 想验证「换了 DNS 有没有变」，看 `dns` 段，不要看 `probe` 段。

---

## 7. QUIC 不通

> 症状：页面外壳能开但加载不全。

### 排查步骤

1. **先确认目标站到底支不支持 QUIC**：

   ```sh
   python3 cdn/quic_probe.py
   ```

   输出 `支持 QUIC (Version Negotiation, rtt=…ms)` / `无响应 (UDP 被丢或不支持 QUIC)`。
   清单里带了两个对照站点，一个国内一个国外 —— 对照结果不同就说明是**链路**问题。

2. **确认 UDP 是不是被透明代理漏过去了**（Redir 只代理 TCP，UDP 直出）：

   ```sh
   nft list table inet quicguard
   ```

   表里应有针对 UDP 443/8443 的拦截规则，并且**计数器在增长**。
   计数不涨 → 规则没生效（见 [第 12 节](#12-nft-表掉了)）。

3. **看 mihomo 里的连接是不是停在半截**：

   ```sh
   MIHOMO_SECRET=xxx python3 mihomo/mihomo_api.py conns
   ```

4. **对照实验**：临时全局拦掉 UDP 443/8443 再复测浏览器 ——
   页面能拉全就说明是 QUIC 直出导致的地区误判。

### 原因 / 解法

- **Redir 只代理 TCP**：QUIC（UDP 443）根本不进 mihomo，
  直出 WAN 带本地出口 IP → 目标站按地区降级或拒绝 →
  表现为「外壳能开、UI 加载不全」。
  解法是拦 UDP 443/8443 让它回落 TCP。
- **但全局拦会伤国内应用**：国内应用的 QUIC 被打掉后，
  Linux 不把 ICMP 端口不可达交给应用，应用只能等握手超时才回落 ——
  表现为「一堆图慢慢出」。
  **正确做法是给国内目标开豁免**（在拦截链首放行国内目标集合）。
- **判定浏览器类问题先看传输层**，别一上来就改规则。

---

## 8. 设备重启后服务起不来

### 排查步骤

1. **确认不是「本机漂到别的 SSID」**（笔记本自动连了另一个已保存的网络，
   看起来像路由器挂了）：

   ```sh
   ipconfig        # IPv4 是不是还在路由器的网段
   route print     # 有没有到路由器网段的路由
   arp -a          # 路由器的 MAC 还在不在
   ```

2. **确认是重启还是半死**：

   ```sh
   uptime          # 刚重启的话，uptime 会很小
   ```

3. **看开机自启链路**：

   ```sh
   grep "mkdir -p" /etc/rc.local
   ls -d /tmp/ShellCrash
   ls -d /var/etc /var/lib /var/run
   ```

4. **看守护有没有把 cron 补回来**：

   ```sh
   crontab -l
   ```

   应该有 `guardian.sh` 与 `start_legacy_wd.sh` 两行；少了守护会补（`guardian.sh` 收尾）。

5. **看核心起没起**：

   ```sh
   netstat -lntp | grep -E ':7892|:9999|:1053'
   ```

6. **兜底**：跑一次只诊断的恢复脚本看全貌，再决定是否执行完整修复：

   ```sh
   sh openwrt/recover-now.sh check
   sh openwrt/recover-now.sh        # 完整修复
   ```

### 原因 / 解法

- **`/tmp` 是 tmpfs**：`/tmp/ShellCrash` 重启后**整个目录不存在** ——
  代理起不来。`rc.local` 开机第一步就是 `mkdir -p`。
- **`/var` 是指向 tmpfs 的相对软链**：`/var/etc` 等目录重启后没了，
  dnsmasq 依赖 `-C /var/etc/dnsmasq.conf.*` → dnsmasq 起不来。
  `rc.local` 按 `VAR_RUNTIME_DIRS` 兜底重建。
- **`start.sh` 重写 crontab**：把守护行冲掉 → 之后没人兜底。
- **含 DNS 劫持的表早加载**：开机有一段死窗口，见 [第 1 节](#1-连上了-wifi-但没网)。

---

## 9. 守护进程误判

> 症状：该动的没动，或不该动的动了。

### 排查步骤

1. **先看守护到底做了什么**（`FIX` / `ALERT` / `ERROR` 行）：

   ```sh
   grep -E 'FIX|ALERT|ERROR|WARN' "$GUARDIAN_LOG" | tail -30
   logread | grep guardian
   ```

2. **不确定它会不会动，就先干跑**：

   ```sh
   sh openwrt/guardian.sh --dry-run
   ```

   干跑只检测只报告，切组 / 拉起 / 重载 / 改 crontab / 删文件**一律不执行**。

3. **「该动却没动」→ 查配置键是否配全**：

   ```sh
   sh -n "$DEVICE_CONF"                       # 语法对不对
   grep -E '^(AI_GROUP|CLEAN_GROUP|CLEAN_NODE|POOL_GROUP|POOL_FALLBACK_GROUP|AI_BAD_NODES|POOL_BLOCKED_NODES)=' "$DEVICE_CONF"
   ```

   任何一项为空 → 对应动作**直接跳过**（这是有意设计，见 P18）。
   另外每项动作往往要**好几个键同时非空**才生效。

4. **「不该动却动了」→ 查坏节点通配是不是太宽**：

   ```sh
   grep -E '^(AI_BAD_NODES|POOL_BLOCKED_NODES)=' "$DEVICE_CONF"
   ```

   `|` 分隔的 shell 通配，`*` 匹配任意长。`*-备用*` 这种很宽。

5. **「核心没了它不拉」→ 这是设计**：最近 `ALIVE_STALE_SEC`（默认 1800 秒）
   没有存活记录 + 没有 pid 文件 → 判定为人为停止，刻意不拉。
   要它拉就把 `ALIVE_STALE_SEC` 调小，或手动 `sh /etc/ShellCrash/start.sh start`。

6. **维护前后记得停/挂守护**：

   ```sh
   sed -i '/guardian/d' /etc/crontabs/root && /etc/init.d/cron restart   # 停
   # ...维护...
   echo "*/5 * * * * /bin/ash /etc/ShellCrash/guardian.sh" >> /etc/crontabs/root
   /etc/init.d/cron restart                                             # 挂
   ```

### 原因 / 解法

守护的设计是「**只在检测到偏离已知良好状态时才动手**」，
且每种修复**幂等可回退**。它宁可什么都不做，也不拿猜的名字去 PUT 别人的组。
所以「守护没动作」的第一嫌疑永远是**配置没配全**，不是脚本坏了。

---

## 10. 控制 API 连不上

> 症状：连接超时，或一律 401 Unauthorized。

### 排查步骤

1. **先看端口在不在**：

   ```sh
   netstat -lntp | grep 9999
   ```

2. **看能不能连通**（不带鉴权也应返回 401，而不是超时）：

   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' -m 5 http://127.0.0.1:9999/version
   ```

   超时 → 核心没起或控制端口没开。
   401 → 鉴权问题，看第 3 步。

3. **确认 secret**：真值在设备的
   `/etc/ShellCrash/configs/ShellCrash.cfg` 的 `secret=` 行。
   `openwrt/guardian.sh` 也是从那里**现读**的，脚本里不存凭据。

   ```sh
   grep '^secret=' /etc/ShellCrash/configs/ShellCrash.cfg
   ```

   工具侧：`export MIHOMO_SECRET=<那个值>`。
   `mihomo/mihomo_api.py` **缺 secret 会直接报错**（不会拿空 secret 去换一个含义不明的 401）；
   `mihomo/latency_probe.py` 缺 secret 则**不报错**，只打印 `HTTP401`。

4. **控制 API 是不是在监听 IPv6**：地址写 `127.0.0.1` 时只走 IPv4。
   `mihomo_api.py` 支持直接给 IPv6 字面量（`MIHOMO_HOST`），
   会自动给 Host 头加方括号。

5. **工具没输出、等很久**：API 失败会**重试 12 次**（每次隔 0.6 秒）。
   先单独探端口确认核心在，再跑工具。

### 原因 / 解法

- **secret 换了但没同步**：控制台开了 secret，所有 API 调用必须带
  `Authorization: Bearer <secret>`，否则一律 401。
- **secret 配在错的地方**：本仓**不存凭据**（见 [SECRETS.md](SECRETS.md)），
  真值只在设备上。

---

## 11. 审计结果与实况对不上

### 排查步骤

1. **确认审计输入的 `config.yaml` 是**运行态那份：

   ```sh
   ls -l /tmp/ShellCrash/config.yaml
   ```

   审计是**离线**的 —— 它读文件，不连控制 API。拿了旧文件审计的就是旧状态。

2. **看实况**（运行态证据）：

   ```sh
   MIHOMO_SECRET=xxx python3 mihomo/mihomo_api.py conns
   MIHOMO_SECRET=xxx python3 mihomo/mihomo_api.py rulestats
   ```

3. **看有没有 `error.yaml`**（被回退过）：

   ```sh
   ls -l /tmp/ShellCrash/error.yaml
   ```

4. **数据集版本差**：审计用**文本** geosite 模拟 `RULE-SET,cn`，
   运行态用编译好的 `cn.mrs`。文本里有、mrs 没收录的域名仍走后面的规则。

5. **规则工具的已知局限**（`mihomo/rule_audit.py`）：
   - 模拟器把 `*.X` 与 `+.X` 当同一回事（两种前缀都剥掉）；
   - 广告误伤检测**只检查广告组**，其它组的关键词误伤不覆盖；
   - `findings.json` 落在**当前目录**，不是报告所在目录。

### 原因 / 解法

审计是**方向性**证据，不是运行态真相。
两者对不上时，优先级是：**实况 > 审计**。
但「实况为什么是这样」的解释权归审计 —— 先用它缩小范围，再用实况确认。

---

## 12. nft 表掉了

> 症状：表不在了，或者规则写了却不生效。

### 排查步骤

1. **看表在不在**：

   ```sh
   nft list tables
   ```

2. **不在 → 看守护补了没**：

   ```sh
   grep 'nft 表' "$GUARDIAN_LOG" | tail
   ```

   守护会从 `$NFT_DIR/<表名>.nft` 重载（默认 `NFT_DIR=/etc`）。
   源文件也没有的话，日志里是 `ERROR: nft 表 inet <表> 缺失且 <路径> 不存在`。

3. **在，但规则不对** —— 守护**只管「表缺失」，不管「内容对错」**。
   手工重载，注意要**先 destroy 再 load**：

   ```sh
   nft destroy table inet quicguard
   nft -f /etc/quicguard.nft
   nft list table inet quicguard      # 确认规则真的在
   ```

4. **规则写了但一点效果都没有** → 查是不是写在了 **nat 链**里
   （nft 不允许 nat 链用 `reject`，**命令静默失败**）。

5. **检查计数**：规则带 `counter` 的话，计数不涨就是没走到。
   注意输出格式是 `counter packets N bytes M reject`，
   匹配时用 `grep -q "udp dport { 443, 8443 } counter packets"` ——
   只写 `counter reject` 会误判成「规则缺失」。

6. **开机时表没加载**：含 DNS 劫持的表要**等核心 DNS 端口就绪**才加载；
   `rc.local` 等不到就交给守护补载。查 syslog：

   ```sh
   logread | grep rc.local
   ```

### 原因 / 解法

- `nft -f` 的 `add table` **不替换**已有表 → 必须 `destroy` 再 `load`。
- nat 链不支持 `reject` → 规则静默失效。
- 守护的补载判据是「表在不在」，不是「内容对不对」。

---

## 13. 设备突然整机重启

### 排查步骤

1. **看是不是 OOM**（重启原因在 RAM 型 tmpfs 上，重启即丢，
   要靠 overlay 上持久化的日志反查）：

   ```sh
   dmesg | tail -40
   awk '/^MemAvailable/{print}' /proc/meminfo
   df -k /tmp
   ```

2. **看 `/tmp` 是不是被写满**：`/tmp` 是内存盘，写满 = 内存被占光 = OOM。

3. **看守护的水位告警**：

   ```sh
   grep -E '内存|tmpfs|内存盘' "$GUARDIAN_LOG" | tail
   ```

   形如 `WARN: /tmp 内存盘已用 92%（…K/…K），接近撑爆会 OOM 并触发看门狗重启`。

4. **看是不是被看门狗重启**（代理挂了触发的整机重启）：

   ```sh
   logread | grep -iE 'watchdog|reboot'
   ```

### 原因 / 解法

- **`/tmp` 写满 → OOM → 看门狗整机重启**。
  `guardian.sh` §6 在 80% 就开始清理，但**只清白名单**里的文件 ——
  自己的大文件要登记进 `TMPFS_CLEAN_FILES`。
- **可用内存低**：`MemAvailable` 低于 `MEM_LOW_MB`（默认 30 MB）时守护会告警。
- **闪存（overlay）写满**表现**不一样**（是 ENOSPC，不是 OOM）——
  本仓目前**没有**对 overlay 水位的守卫，这条属于已知缺口。

---

## 14. 工具报配置语法错误

### 排查步骤

1. 配置文件按 **shell 语法**解析，所以先过一遍语法检查：

   ```sh
   sh -n /etc/openwrt-ops/device.conf
   ```

2. 报错信息里指出行号，对照 `openwrt/conf/device.conf.example` 核对键名。

3. 注意：**语法错误会让整份配置被忽略**，脚本退化成「什么都没配」的默认状态 ——
   表现为「守护什么都不做」，而不是报「配置坏了」。

4. 只想临时覆盖一两个值，用**环境变量**绕过配置文件：

   ```sh
   NFT_TABLES="quicguard" sh openwrt/guardian.sh --dry-run
   ```

### 原因 / 解法

配置是**三段式优先级**的顶端：环境变量 > 配置文件 > 内置默认值。
语法错误时走的是**内置默认值**那一档，不是「报错退出」。
定位到问题后改完记得再 `sh -n` 过一遍。

---

## 15. 排障时容易白跑的三件事

| 白跑的事 | 为什么白跑 | 正确做法 |
|---|---|---|
| 在路由器上 `curl` 境外地址 | 路由器自身流量**不走**透明代理 | 加 `-x http://127.0.0.1:7890` 显式走代理 |
| 改 `/tmp/ShellCrash/config.yaml` | mihomo 的 `SAFE_PATHS` 会拒；运行态产物本来就是生成的 | 改**源**（规则 / 模板），再重新生成 |
| `pgrep -f CrashCore` 数实例 | 会匹配到它自己 | `netstat -lntp \| grep -E ':7892\|:9999\|:1053'` |
