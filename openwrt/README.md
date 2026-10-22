# openwrt/ —— OpenWrt 设备侧运维脚本

> **一句话**：五个可以直接扔到任意 OpenWrt 设备上跑的运维脚本 ——
> 网络守护、大流量守卫、离线恢复、开机自启模板、ShellCrash 更新后回灌补丁；
> **不含任何设备标识**，所有跟「你这台机器」有关的值都在 `conf/device.conf` 里。

---

## 1. 这五个脚本

| 文件 | 干什么 | 典型调用 |
|---|---|---|
| `guardian.sh` | 网络守护：核心存活、nft 表补载、策略组出口复原、出口健康、`/tmp` 水位 | cron `*/5 * * * *`（试跑加 `--dry-run`） |
| `bulk-guard.sh` | 大流量组守卫：按**真实吞吐**决定走公共池还是机场；慢时先在公共池内按吞吐缓存换节点（mihomo 的 `url-test`/`fallback` 只测首包，不测带宽） | cron `*/3 * * * *`（`--status` 看当前判定，`--dry-run` 只报告） |
| `recover-now.sh` | 离线恢复：DNS 解析全失败 / 代理离线 / 「连上 WiFi 但没网」 | 人工，或 Windows 侧推过去跑 |
| `rc.local` | 开机自启**模板**：建 tmpfs 运行时目录、兜底重建 `/var`、按需加载 nft 表 | 覆盖 `/etc/rc.local` |
| `post-sc-update.sh` | ShellCrash 官方脚本更新后，把本地补丁恢复回来 + 补 cron + 启动 + 验收 | 每次更新完跑一次 |

设计原则（五个脚本一致）：

1. **只检测 + 最小化修复**，绝不删防火墙链、绝不重启路由器、绝不改订阅；
2. 每种修复都**幂等**，跑第二遍不会把设备搞坏；
3. 关键动作失败**显式报错**（写日志 + `logger`），不静默吞掉；
4. **设备相关的值全部外置**到配置，脚本本身可以直接公开。

`bulk-guard.sh` 的取舍（2026-10-22 重写）：

1. **空闲时才跑探测下载**（切组会重置 TCP，正在跑的下载必断）。探测文件用 4MB ——
   同一公共节点实测 2MB 1.19、4MB 1.65、8MB 2.07、20MB 2.67 MB/s，小样本会被
   TCP 慢启动 + 300–500ms RTT 低估约一倍。跑满超时但收到了数据按实测速率算慢，
   不再记「探测无效」—— 84.8 KB/s 的公共节点正好卡在这条路径上。
2. **有活跃连接时按 connection id 求正增量之和**（关掉的连接不会把总和拉低），
   连续两个窗口低于 200 KB/s 才动；第一个窗口慢、第二个 0 字节按停滞处理，
   两个窗口都 0 才算暂停。
3. **确认为慢先在公共池内部换节点**：按吞吐缓存从快到慢、每个下载会话最多试
   `BULK_MAX_TRY`（默认 2）个，都不行才切机场。切换会断流，所以有上限。
4. 机场停留 `BULK_RETURN_COOLDOWN` 秒且连续空闲 `BULK_IDLE_SWITCH` 秒后切回公共池，
   并钉住缓存里吞吐最好的节点。mihomo 的控制 API 只能钉、不能解钉，所以公共池
   被钉住后 URLTest 不再自动切换 —— 脚本每轮会先做一次钉住节点的健康检查，
   死了就换活的。

它只改 `BULK_GROUP` 与 `BULK_PUBLIC` 这两个组的选择，不拉起 / 停止核心、
不改配置、不写 crontab。

---

## 2. 配置：唯一的「这台设备」入口

所有跟设备相关的值（策略组名、节点名、路径、端口、阈值）都从 `device.conf` 读，
样例见 [conf/device.conf.example](conf/device.conf.example)。

**优先级：同名环境变量 > `device.conf` > 脚本内置默认值。**

配置文件路径的查找顺序：

1. 环境变量 `DEVICE_CONF` 指定的文件；
2. `<脚本所在目录>/conf/device.conf`；
3. `/etc/openwrt-ops/device.conf`（设备上建议统一放这里）。

配置文件按 shell 语法解析（可以带引号）。**改动前先 `sh -n device.conf` 过一遍** ——
语法错误的配置会被跳过，脚本退回默认值继续跑，不会把设备带沟里。

最少要配的三样：

```sh
AI_GROUP="你的 AI 接口组名"     # 要盯的策略组
CLEAN_GROUP="你的干净出口组名"  # 干净出口组
CLEAN_NODE="你的干净节点名"     # 干净出口组里那个可信节点
```

没配的项**会被跳过**（守护不会瞎猜你的组名去 PUT），而不是用内置默认值乱改。

### 试跑（不改设备状态）

```sh
sh openwrt/guardian.sh --dry-run
```

干跑模式只做检测与报告：切组、拉起核心、重载 nft 表、改 crontab、删临时文件**一律不执行**，
只在日志里写「本应……」。

`recover-now.sh` 与 `post-sc-update.sh` 用**位置参数**表达同样的意思：

```sh
sh openwrt/recover-now.sh check      # 只诊断，不改任何东西
sh openwrt/post-sc-update.sh check    # 只检查，不恢复
```

---

## 3. 部署（以 OpenWrt + ShellCrash 为例）

```sh
# 1) 脚本与配置
scp -r openwrt/conf root@<路由器>:/etc/openwrt-ops/    # 配置
scp openwrt/guardian.sh root@<路由器>:/etc/ShellCrash/guardian.sh
scp openwrt/bulk-guard.sh root@<路由器>:/etc/ShellCrash/bulk-guard.sh
ssh root@<路由器> 'chmod +x /etc/ShellCrash/guardian.sh /etc/ShellCrash/bulk-guard.sh'

# 2) 挂 cron（守护每 5 分钟；大流量守卫每 3 分钟）
ssh root@<路由器> 'echo "*/5 * * * * /bin/ash /etc/ShellCrash/guardian.sh" >> /etc/crontabs/root'
ssh root@<路由器> 'echo "*/3 * * * * /bin/ash /etc/ShellCrash/bulk-guard.sh" >> /etc/crontabs/root'
ssh root@<路由器> '/etc/init.d/cron restart'

# 3) 开机自启：先备份再覆盖
ssh root@<路由器> 'cp /etc/rc.local /root/backup/rc.local.bak-$(date +%Y%m%d-%H%M%S)'
scp openwrt/rc.local root@<路由器>:/etc/rc.local
```

> `bulk-guard.sh` 要生效，还需要两件设备侧的事：`device.conf` 里填
> `BULK_GROUP` / `BULK_PUBLIC` / `BULK_AIRPORT`；`rules` 里把探测域
> （默认 `proof.ovh.net`）固定指向 `BULK_GROUP`，否则探测会走默认出口，
> 测的是别的组。

> `rc.local` 是**模板** —— 直接覆盖前先把自己的 `device.conf` 配好，
> 否则它会用内置默认路径去加载 nft 表。
> 覆盖后**必须重启验证**（`/etc/init.d/done` 在 S95 调 `sh /etc/rc.local`）。

维护前先停守护，别让它在你升级时把代理复活：

```sh
sed -i '/guardian/d' /etc/crontabs/root && /etc/init.d/cron restart
```

---

## 4. 与「设备实例」的关系

- **本目录 = 通用版**：任何 OpenWrt 设备都能用，不含任何设备标识。
- **设备实例 = 私有仓**：某台设备**实际在跑**的那份脚本
  （已经部署到路由器上），带它自己的策略组名与节点名。

两边**同源不同值**：通用版把设备相关的值抽成了配置项，设备实例里那些值是写死的。
改动方向永远是「先改通用版 → 再同步设备实例」，不要只改一边。

---

## 5. 依赖

设备上需要：

- `ShellCrash`（默认 `/etc/ShellCrash`）—— 提供 `start.sh` / `task/task.sh` / `starts/*`
- `mihomo` 核心 —— 控制 API（默认 `127.0.0.1:9999`）、透明端口（默认 `7890`）
- `curl`、`nft`、`awk`、`sed`、`grep`、`pidof`、`netstat`、`df`、`nslookup`、`crontab`、`logger`

脚本会从 `/etc/ShellCrash/configs/ShellCrash.cfg` 的 `secret=` 行**现读** API 密钥 ——
**脚本里不存任何凭据**。换了密钥不用改脚本，但所有 API 调用要一起换，否则静默 `Unauthorized`。

---

## 6. 免责声明

这些脚本会**直接改设备状态**（重启服务、重载防火墙、改 crontab、改策略组）。
执行前先备份、先读懂在改什么，出问题先跑 `recover-now.sh check`（只诊断，不改东西）。

所有结论都来自**特定固件版本、特定订阅、特定时间点**下的实测，
换固件、换订阅、换节点之后**必须重新验证**。使用后果自负。
