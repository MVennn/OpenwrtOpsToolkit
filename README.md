<div align="center">

<img src="https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/raw/main/assets/logo.png" width="128" alt="OpenwrtOpsToolkit">

# OpenwrtOpsToolkit

**给 OpenWrt 与 mihomo 用的运维工具箱** —— 设备侧守护与离线恢复脚本、mihomo 控制面诊断工具、站点可达性专项排查工具。

能只读就只读，要动手的只做最小化修复。

![流水线](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/badges/main/pipeline.svg) ![源码仓库](https://img.shields.io/badge/源码仓库-GitLab-FC6D26?logo=gitlab&logoColor=white) ![问题反馈](https://img.shields.io/badge/问题反馈-Issues-FC6D26?logo=gitlab&logoColor=white) ![OpenWrt](https://img.shields.io/badge/OpenWrt-任意设备-00B5E2?logo=openwrt&logoColor=white) ![mihomo](https://img.shields.io/badge/mihomo-Clash.Meta-9B59B6) ![Python](https://img.shields.io/badge/Python-3.8%2B-3776AB?logo=python&logoColor=white) ![License](https://img.shields.io/badge/License-MIT-blue)

</div>

---

## 这是什么

三个域，解决同一类问题的三个侧面：

| 目录 | 干什么 | 适合谁 |
|---|---|---|
| [`openwrt/`](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/tree/main/openwrt) | 设备侧运维脚本：网络守护、离线恢复、开机自启模板、ShellCrash 补丁恢复 | 自己在 OpenWrt 上跑透明代理的人 |
| [`mihomo/`](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/tree/main/mihomo) | mihomo 控制面诊断：规则审计、实时日志、连接快照、节点延迟 | 用 Clash.Meta / mihomo 内核的人 |
| [`cdn/`](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/tree/main/cdn) | 站点可达性专项：CDN 连通性、DNS 路径、规则命中、QUIC 能力 | 排查「某个站点打不开 / 被限速」的人 |

- **设备侧**（`openwrt/`）：代理跑久了会静默劣化 —— 出口组被改坏、nft 表掉了、核心假死。
  守护进程负责发现并做**最小化修复**；离线恢复脚本负责在「连得上 WiFi 但没网」时把链路救回来。
- **控制面**（`mihomo/`）：规则到底生效了没有？「声明的分组」和「实际命中的分组」是不是一致？
  哪个节点握手最快？这些都能离线查，不用改任何配置。
- **站点侧**（`cdn/`）：某个站点打不开，是 DNS 走了境外、规则没命中 cn 集、还是 CDN 不支持 QUIC？
  三个环节分开测，结论才站得住。

**设计原则**：能只读就只读（`mihomo/` `cdn/` 全部只读，不切组不改配置）；
要动手的（`openwrt/`）一律**做最小化修复**，绝不删防火墙链、绝不重启设备、绝不改订阅。

每个脚本干什么、会不会改设备状态，见 [docs/TOOLS.md](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/blob/main/docs/TOOLS.md)；
会改什么、怎么改的机制正本见 [docs/ARCHITECTURE.md](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/blob/main/docs/ARCHITECTURE.md)。

## 适用环境

| 项 | 要求 |
|---|---|
| 设备 | 任意 OpenWrt（需 `uhttpd` / `ubus` / `rpcd`；`openwrt/` 还需要 `nft` / `busybox sh`） |
| 代理 | ShellCrash 或任何基于 **Clash.Meta / mihomo** 内核的部署 |
| 本机工具 | `mihomo/` `cdn/` 需要 **Python 3.8+**（只依赖标准库，**除** `mihomo/rule_audit.py` 需要 `PyYAML`）；`openwrt/` 是纯 shell |
| 网络 | 诊断类工具需要能连到 mihomo 控制 API（默认 `http://127.0.0.1:9999`） |

> **已验证环境**：小米 AX3000T / OpenWrt 25.12.6 / mihomo v1.19.32 / ShellCrash。
> 那是**验证环境**，不是支持范围 —— 脚本只依赖上面列的那些通用能力。

## 使用

### 1. 拿配置

```sh
git clone <本仓>
cd OpenwrtOpsToolkit
cp openwrt/conf/device.conf.example openwrt/conf/device.conf
# 按你的环境改：策略组名、节点名、nft 表路径
```

**所有设备相关的值都在 `openwrt/conf/device.conf` 里**，脚本的读取顺序是
**环境变量 → 配置文件 → 占位符默认值**。配置文件本身不入库（见 `.gitignore`），
样例 `device.conf.example` 入库。凭据一律走环境变量：

| 变量 | 用途 |
|---|---|
| `MIHOMO_API` | mihomo 控制 API 地址（默认 `http://127.0.0.1:9999`） |
| `MIHOMO_SECRET` | mihomo 控制 API 的 secret |
| `DEVICE_CONF` | `device.conf` 的路径 |

位置索引见 [docs/SECRETS.md](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/blob/main/docs/SECRETS.md)。

### 2. 跑诊断（只读，不改任何配置）

```sh
# 规则审计：13k 条规则里，哪些被遮蔽了、哪些指向了错的组
# （这个脚本要解析 mihomo 的 config.yaml，需要 PyYAML：pip install pyyaml）
python3 mihomo/rule_audit.py <config.yaml> <proxies.json> <lists目录> REPORT.md

# 控制面连通性与节点延迟
MIHOMO_API=http://127.0.0.1:9999 MIHOMO_SECRET=xxx python3 mihomo/latency_probe.py
```

### 3. 装守护（会改设备状态，先读 docs/ARCHITECTURE.md）

```sh
# 拷到路由器并试跑
scp openwrt/guardian.sh root@<路由器IP>:/etc/ShellCrash/guardian.sh
ssh root@<路由器IP> 'sh /etc/ShellCrash/guardian.sh --dry-run'
```

## 反馈

脚本在你的设备上跑不通、诊断结论对不上、想要新的排查工具，到
[Issues](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/issues) 反馈。请尽量带上：
设备与固件版本、mihomo / ShellCrash 版本、哪个脚本、报错原文。
踩坑与排错可以先查 [docs/PITFALLS.md](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/blob/main/docs/PITFALLS.md)
与 [docs/TROUBLESHOOTING.md](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/blob/main/docs/TROUBLESHOOTING.md)。

想参与贡献，见 [CONTRIBUTING](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/blob/main/CONTRIBUTING.md)；
安全问题按 [SECURITY](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/blob/main/SECURITY.md) 报告。

## 免责声明

本项目仅供学习与个人运维使用。

- `openwrt/` 的脚本会**直接改路由器上的系统状态**（重生成配置、重载防火墙、恢复 crontab）。
  执行前请确认自己有把握，先备份、先 `--dry-run`。
- 本仓库**不保存任何凭据值** —— secret 与口令一律走环境变量（见 [docs/SECRETS.md](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/blob/main/docs/SECRETS.md)）。
- 所有结论都是在特定固件、内核与订阅下实测的，换环境后**必须重新验证**。
- 本项目与 OpenWrt、ShellCrash、mihomo 及其关联方不存在任何隶属、合作、授权或支持关系。
- 使用本项目造成的任何后果由使用者自行承担。

## 开源鸣谢

本仓库建立在这些开源项目之上（详见 [NOTICE](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/blob/main/NOTICE)）：

| 项目 | 用途 |
|---|---|
| [**OpenWrt**](https://openwrt.org/) | 目标平台：`/etc/rc.local`、`fw4`/`nft`、busybox 工具链 |
| [**ShellCrash**](https://github.com/nekoii/shellcrash) | 代理配置生成与运行时（`openwrt/` 脚本面向它的目录约定，不含其代码） |
| [**mihomo**](https://github.com/MetaCubeX/mihomo) | 代理内核与控制 API（`mihomo/` 诊断工具面向它的 RESTful API） |
| [**Python**](https://www.python.org/) | 诊断工具的运行时（标准库为主） |

上游版本与派生边界见 [docs/UPSTREAM.md](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/blob/main/docs/UPSTREAM.md)。

## 许可证

本仓库以 [MIT License](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/blob/main/LICENSE) 发布。
第三方组件的版权与许可证声明见 [NOTICE](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/blob/main/NOTICE)。

> 本仓的脚本**会修改路由器状态**。在别人的设备上用之前，请先读
> [docs/ARCHITECTURE.md](https://gitlab.com/M.Venn/OpenwrtOpsToolkit/-/blob/main/docs/ARCHITECTURE.md) 的「会改什么」一节。
