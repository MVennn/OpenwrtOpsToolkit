---
name: router-offline-recovery
description: 路由器「连上 WiFi 但没网」的离线恢复配方（先摘 DNS 劫持恢复直连再修代理），以及助手在用户 PC 上远程操作路由器时必须写成
  .bat 交给用户双击的流程
metadata:
  node_type: memory
  type: project
  originSessionId: session_5fe631d5f57189c091c6560e6cbdf7ab
---

## 2026-10-20 15:5x 事故：WiFi 连上了但没网

**现象**：用户报「wifi 又炸了，能连上但是没网」。PC 侧 ping <路由器IP> 全丢包、
ARP 表里没有路由器、80/443/9999/7892 全不通；但 PC 同时**能上外网**（当时 PC 挂在手机热点上）。
恢复脚本里 `uptime` 显示 **12 分钟** → 路由器**在此之前整机重启过**，回来后网络处于半死状态。
（`dmesg` 在 RAM 型 tmpfs，重启即丢，重启原因要靠 overlay 上持久化的
`/etc/router-health/health-*.log` 快照反查。）

**恢复配方（`openwrt/recover-now.sh`，跑在路由器上）**
顺序不能乱 —— 先让内网直连恢复，再修代理：
1. 修 `fake_ip_filter`：去空行/注释/重复项（我手滑在追加时留了一个空行，防御性清理）。
2. **先摘 DNS 劫持**：`nft delete table inet googleroute` + `inet shellcrash`，
   再 `/etc/init.d/dnsmasq restart` → 内网立刻走直连 DNS，至少能上网（此阶段外网不代理）。
3. 清运行态：`rm -f /tmp/ShellCrash/config.yaml /tmp/ShellCrash/error.yaml`，
   再 `sh /etc/ShellCrash/start.sh start`（**必须用 start.sh，不能用 /etc/init.d/shellcrash start**）。
4. 重新加载自建表：`nft -f /etc/quicguard.nft`、`/etc/googlecn.nft`、`/etc/googleroute.nft`。
5. **`/etc/init.d/firewall restart`** —— `start.sh` 会重写 fw4，停在半加载状态就是「连上没网」的成因。
6. 检查 WAN 口地址与默认路由，缺了就 `ifup wan`。
7. **恢复 crontab**：`start.sh` 会重写 crontab，可能丢掉 `task.sh 106`（每 10 分钟保存面板选择）
   与 guardian/legacy 看门狗行 → 要逐条 grep 补回。
8. 验证：7892/1053/9999 端口、`nslookup`、`baidu_direct`、`google_via_proxy`、
   `gemini_via_proxy`、以及 `support.google.com` 的 `var cc=IN`。

## 助手侧的工作方式约束（重要）

**助手的 Bash 工具跑在用户这台 PC 上，而 PC 一次只能连一个 WiFi。**
- 路由器 SSID = `<你的路由器SSID>`；用户手机热点 = `<你的热点名>`；路由器 LAN = `<路由器IP>`。
- 路由器 LAN 的 IPv6 `<REDACTED-ipv6-pd>1` **只通 ICMP**（TCP 被 WAN 防火墙挡，
  dropbear 也只监听 IPv4）→ 在热点上无法回连 SSH。
- 所以**不要自作主张把用户的 WiFi 切走**：那会直接掐掉他当时的上网（他就是靠热点在用电脑）。
- 正确姿势：把操作写成 **纯 ASCII 的 .bat 放桌面**，让用户双击；
  .bat 内部自己「切到路由器 WiFi → SSH 执行 → 切回热点」。
- 免密 SSH：`SSH_ASKPASS=<本地 askpass.sh> SSH_ASKPASS_REQUIRE=force DISPLAY=:0`
  配 Git 的 `/usr/bin/ssh`（Windows 自带 ssh 不行）。askpass 已存
  `openwrt/` 下的 askpass 脚本。
- 现成资产：`router/recover-now.sh`（路由器端修复）、`router/verify-fix.sh`（体检+补 cron）、
  `tools/fix-router.sh`、`tools/verify-gemini.sh`（PC 端调度）、
  桌面 `修复路由器网络.bat` / `复测Gemini页面.bat`。
- .bat 内容**必须纯 ASCII**（含中文的 .bat 双击秒退，见 [[windows-powershell-utf8-script-trap]]）；
  `taskkill //IM chrome.exe` 这种粗粒度杀进程要换成按命令行匹配
  （`Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'verify-prof' }`），
  否则会误杀用户自己的浏览器。

## 2026-10-20 当晚补的两道防线（防「下次又这样」）

1. **`/etc/rc.local` 里 `googleroute.nft`（含 DNS 劫持 53→1053）必须等核心 1053 端口就绪再加载**，
   等不到就不加载（交守护进程补载）。否则重启后有一段「内网 DNS 指向没人监听的端口 → 全家连上却没网」的死窗口。
2. **`guardian.sh` 加 /tmp 水位守卫**：≥80% 就清理已知临时大文件（/tmp 是 116MB tmpfs，撑爆 = OOM → 看门狗整机重启）。
3. **`start.sh start` 会重写 crontab**，恢复流程里必须逐条 grep 补回
   `guardian.sh` / `start_legacy_wd.sh` / `task.sh 106` 三行（`task.sh 106` 是每 10 分钟保存面板选择用的，丢了会导致选中的节点不落盘）。

相关：[[chrome-lna-fakeip-conflict]]、[[shellcrash-ai-routing-fix]]、[[ax3000t-oom-tmpfs-rootcause]]、[[windows-powershell-utf8-script-trap]]

## 2026-10-20 22:00 补充：路由器重启后笔记本"漂到别的 SSID"，SSH 就此失联

**场景**：路由器重启（或我手动重启做冷启动验证）→ WiFi AP 消失 → 笔记本**自动连上另一个已保存的
SSID**（本例是 10.241.32.0/24 的公共网）→ 路由表里**根本没有 10.0.0.0/24 的路由** →
`ping <路由器IP>` 全丢、`ssh` 超时，看起来像"路由器挂了"。

**判据**：`ipconfig` 显示的 IPv4 不在 10.0.0.x 段 + `route print` 里没有 10.0.0.0/24，
且 `arp -a` 里还留着 `<路由器IP> → a4-a9-30-c0-33-68`（小米 OUI）⇒ **路由器多半是活的，是本机漂了**。

**恢复的坑**：
- `netsh wlan connect name="<你的路由器SSID>"` 在这台 Windows 11 上**用不了**：
  报"需要位置权限"且"需要提升为管理员"（即使 `HKCU\...\location\NonPackaged\Executables\netsh.exe`
  已经写了 `Value=Allow`，因为 WlanQueryInterface 这类接口仍要求提权）。
  → 改 `netsh wlan add profile filename=...` 也不行（需要同样的权限）。
- **可行路径**：用 computer-use 技能驱动 GUI：`cmd //c start ms-settings:network-wifi` 打不开
  （`ms-settings:` URI 在 Git Bash 的 `cmd //c start` 下不生效），直接起
  `C:\Windows\ImmersiveControlPanel\SystemSettings.exe network-wifi`，再由 GUI 点 SSID。
  设置窗口的 app 名是「设置」（pid 归 ApplicationFrameHost.exe），用 `getApp("设置")` 绑定。
- 绑定之后笔记本自己会切回 10.0.0.39，SSH 立刻恢复。

**更稳的做法**：下次做冷启动验证前，先确认笔记本**不会**漂 —— 或直接接受"漂了再用 GUI 接回来"，
别把它误判成路由器故障。
