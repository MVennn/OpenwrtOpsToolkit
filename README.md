<div align="center">

<img src="https://raw.githubusercontent.com/MVennn/OpenwrtOpsToolkit/main/assets/logo.png" width="128" alt="OpenwrtOpsToolkit">

# OpenwrtOpsToolkit

**给 OpenWrt 与 mihomo 用的运维工具箱**

能只读就只读，要动手的只做最小化修复。

![CI](https://github.com/MVennn/OpenwrtOpsToolkit/actions/workflows/ci.yml/badge.svg) ![源码仓库](https://img.shields.io/badge/源码仓库-GitHub-181717?logo=github&logoColor=white) ![问题反馈](https://img.shields.io/badge/问题反馈-Issues-181717?logo=github&logoColor=white) ![OpenWrt](https://img.shields.io/badge/OpenWrt-任意设备-00B5E2?logo=openwrt&logoColor=white) ![mihomo](https://img.shields.io/badge/mihomo-Clash.Meta-9B59B6) ![Python](https://img.shields.io/badge/Python-3.8%2B-3776AB?logo=python&logoColor=white) ![License](https://img.shields.io/badge/License-MIT-blue)

</div>

---

## 这是什么

给在 OpenWrt 上跑 mihomo 的人用的运维脚本与诊断工具，分三块。

**设备侧守护与离线恢复**（`openwrt/`）：代理跑久了会静默劣化 —— 出口组被改坏、nft 表掉了、核心假死。守护进程巡检到偏离就做最小化修复；「连得上 WiFi 但没网」时用离线恢复脚本把链路救回来。

**mihomo 控制面诊断**（`mihomo/`）：规则到底生效了没有？「声明的分组」和「实际命中的分组」是不是同一个？哪个节点握手最快？这些都能离线查，不改你的任何配置。

**站点可达性专项排查**（`cdn/`）：某个站点打不开，是 DNS 走了境外、规则没命中 cn 集、还是 CDN 不支持 QUIC？三个环节分开测，结论才站得住。

三块的边界：**能只读就只读，要动手的只做最小化修复** —— 诊断工具一律不改配置，设备侧脚本只自愈，不重启路由器、不删防火墙链、不改订阅。完整边界与「会改设备哪些状态」见 [docs/ARCHITECTURE.md](https://github.com/MVennn/OpenwrtOpsToolkit/blob/main/docs/ARCHITECTURE.md)；每个脚本干什么见 [docs/TOOLS.md](https://github.com/MVennn/OpenwrtOpsToolkit/blob/main/docs/TOOLS.md)。

## 环境要求

| 项 | 要求 |
|---|---|
| 设备 | 任意 OpenWrt；`openwrt/` 另需 `uhttpd` / `ubus` / `rpcd` / `nft` / busybox `sh` |
| 代理 | ShellCrash，或任何基于 Clash.Meta / mihomo 内核的部署 |
| 本机 | `mihomo/` `cdn/` 需要 Python 3.8+（只用标准库，`rule_audit.py` 另需 PyYAML）；`openwrt/` 是纯 shell |
| 网络 | 诊断工具要能连到 mihomo 控制 API（默认 `http://127.0.0.1:9999`） |

已验证环境是小米 AX3000T / OpenWrt 25.12.6 / mihomo v1.19.32 / ShellCrash；脚本只依赖上面列的通用能力。

## 使用

1. 克隆仓库（`git clone https://github.com/MVennn/OpenwrtOpsToolkit.git`），把样例配置复制成你自己的：`cp openwrt/conf/device.conf.example openwrt/conf/device.conf`，再填上你的策略组名、节点名、nft 表路径。
2. 凭据与控制 API 地址一律走环境变量（`MIHOMO_API` / `MIHOMO_SECRET` / `DEVICE_CONF`），位置索引见 [docs/SECRETS.md](https://github.com/MVennn/OpenwrtOpsToolkit/blob/main/docs/SECRETS.md)。
3. 先跑只读诊断，结论对得上再谈修：

   ```sh
   MIHOMO_API=http://127.0.0.1:9999 MIHOMO_SECRET=xxx python3 mihomo/latency_probe.py
   ```

4. 要装守护，先干跑：`sh openwrt/guardian.sh --dry-run` 只检测、不动你的设备；确认没问题再去掉 `--dry-run`。
5. 挂 cron、覆盖 `rc.local`、ShellCrash 更新后恢复补丁等部署步骤见 [openwrt/README.md](https://github.com/MVennn/OpenwrtOpsToolkit/blob/main/openwrt/README.md)；跑不动时按现象查 [docs/TROUBLESHOOTING.md](https://github.com/MVennn/OpenwrtOpsToolkit/blob/main/docs/TROUBLESHOOTING.md)。

## 反馈

脚本在你的设备上跑不通、诊断结论对不上、想要新的排查工具，到 [Issues](https://github.com/MVennn/OpenwrtOpsToolkit/issues) 反馈。请带上：

- 设备与固件版本
- mihomo / ShellCrash 版本
- 哪个脚本、执行的完整命令
- 报错原文（贴日志前先抹掉 secret 与节点名）

踩过的坑见 [docs/PITFALLS.md](https://github.com/MVennn/OpenwrtOpsToolkit/blob/main/docs/PITFALLS.md)，按现象查见 [docs/TROUBLESHOOTING.md](https://github.com/MVennn/OpenwrtOpsToolkit/blob/main/docs/TROUBLESHOOTING.md)。想参与贡献见 [CONTRIBUTING](https://github.com/MVennn/OpenwrtOpsToolkit/blob/main/CONTRIBUTING.md)，安全问题按 [SECURITY](https://github.com/MVennn/OpenwrtOpsToolkit/blob/main/SECURITY.md) 报告。

## 免责声明

本项目仅供学习与个人运维使用。

- `openwrt/` 的脚本会**直接改你路由器上的系统状态**（重生成配置、重载防火墙、恢复 crontab）。执行前先备份、先 `--dry-run`。
- 本仓库**不保存任何凭据值** —— secret 与口令一律走环境变量，位置见 [docs/SECRETS.md](https://github.com/MVennn/OpenwrtOpsToolkit/blob/main/docs/SECRETS.md)。
- 所有结论都是在特定固件、内核与订阅下实测的，换环境后**必须重新验证**。
- 使用本项目造成的任何后果由使用者自行承担。

「OpenWrt」「ShellCrash」「mihomo」等名称与标识的权利均归其各自权利人所有。本项目与之不存在任何隶属、合作、授权、认可或支持关系。

## 开源鸣谢

本仓库建立在这些开源项目之上（详见 [NOTICE](https://github.com/MVennn/OpenwrtOpsToolkit/blob/main/NOTICE)）：

| 项目 | 用途 |
|---|---|
| [**OpenWrt**](https://openwrt.org/) | 目标平台：`/etc/rc.local`、`fw4`/`nft`、busybox 工具链 |
| [**ShellCrash**](https://github.com/nekoii/shellcrash) | 代理配置生成与运行时（`openwrt/` 脚本面向它的目录约定，不含其代码） |
| [**mihomo**](https://github.com/MetaCubeX/mihomo) | 代理内核与控制 API（`mihomo/` `cdn/` 诊断工具面向它的 RESTful API） |
| [**Python**](https://www.python.org/) | 诊断工具的运行时（标准库为主） |

上游版本与派生边界见 [docs/UPSTREAM.md](https://github.com/MVennn/OpenwrtOpsToolkit/blob/main/docs/UPSTREAM.md)。

## 许可证

本仓库以 [MIT License](https://github.com/MVennn/OpenwrtOpsToolkit/blob/main/LICENSE) 发布；第三方组件的版权与许可证声明见 [NOTICE](https://github.com/MVennn/OpenwrtOpsToolkit/blob/main/NOTICE)。
