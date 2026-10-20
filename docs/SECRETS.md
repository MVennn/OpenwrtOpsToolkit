# 凭据与设备标识

> **一句话**：本仓**存什么、不存什么**，以及真值该放在哪 —— **只写位置，不写值**。

---

## 1. 原则

| 类别 | 本仓存不存 | 为什么 |
|---|---|---|
| 凭据（口令 / API key / secret） | ❌ **一律不存** | 拿到仓库 = 拿到你的设备 |
| 节点名 / 策略组名 | ❌ **不入库** | 它们是你的订阅内容，且含机场信息 |
| 设备标识（MAC / IPv6 PD / WiFi SSID / 运营商地址） | ❌ **不入库** | 能定位到具体的人与设备 |
| 脚本逻辑、文档、踩坑记录 | ✅ 入库 | 这才是本仓的价值 |

**占位符写法**：`<REDACTED-...>`（凭据）、`<REPLACE-...>`（需要你自己填的值）。

## 2. 凭据怎么给

| 凭据 | 给法 | 谁在读 |
|---|---|---|
| mihomo 控制 API secret | 环境变量 `MIHOMO_SECRET` | `mihomo/*.py`、`cdn/*.py` |
| mihomo 控制 API 地址 | 环境变量 `MIHOMO_API`（默认 `http://127.0.0.1:9999`） | `mihomo/*.py`、`cdn/*.py` |
| 路由器 root 口令 | 由你自己的 ssh 凭据机制提供（密钥 / `SSH_ASKPASS`） | 不经本仓 |

**审计与探测用的可调项**（不是凭据，但同样走环境变量，改了不用动代码）：

| 变量 | 作用 | 默认 |
|---|---|---|
| `MIHOMO_HOST` / `MIHOMO_PORT` | 控制面主机与端口（IPv4 / IPv6 都可） | `127.0.0.1` / `9999` |
| `AUDIT_DIRECT_GROUP` / `AUDIT_AD_GROUP` / `AUDIT_AI_GROUPS` / `AUDIT_FCM_GROUP` | 审计器要核对的策略组 | 占位符组名 |
| `MIHOMO_PROBE_GROUPS` / `MIHOMO_PROBE_NODES` | 延迟探测要看的组与节点 | 空 |
| `MIHOMO_GROUP_PROXY` / `MIHOMO_GROUP_DIRECT` | 判定"这个组该走代理还是直连" | 占位符组名 |
| `MIHOMO_RULE_PATTERN` | 规则扫描的匹配口径 | 所有像域名的 payload |
| `DEVICE_CONF` | `device.conf` 的路径 | 见 [ARCHITECTURE.md](ARCHITECTURE.md) |

**mihomo secret 的真源在设备上**：`/etc/ShellCrash/configs/ShellCrash.cfg` 的 `secret=` 行。
`openwrt/guardian.sh` 也是从那里现读，**不硬编码**。

## 3. 设备相关的值怎么给

`openwrt/conf/device.conf`（**不入库**，样例 `device.conf.example` 入库）：

| 键 | 是什么 | 缺了会怎样 |
|---|---|---|
| `CRASHDIR` | 代理框架的安装目录 | 用默认 `/etc/ShellCrash` |
| `AI_GROUP` / `CLEAN_GROUP` | 你订阅里的策略组名 | 守护**跳过**对应自愈动作（期望行为） |
| `CLEAN_NODE` / `CL_CANDIDATES` | 出口组里的节点 | 守护**跳过**出口组复原 |
| `NFT_DIR` | nft 表的部署目录 | 用默认 `/etc` |
| `ROUTER_HEALTH_DIR` | 自建健康检查目录 | 开机自检那步被跳过 |

**读取顺序**：环境变量 → `device.conf` → 占位符默认值。
配置文件路径用 `DEVICE_CONF` 指定，默认找脚本同目录的 `conf/device.conf`。

> ⚠️ **占位符默认值会让"找不到组"变成"跳过"，而不是"判定为配置损坏"** ——
> 这是有意的：组名对不上时，宁可什么都不做，也不要误判。

## 4. 上传前检查清单

```sh
# 1) 确认没把凭据文件带进去
git ls-files | grep -E '\.(key|crt|pem)$|device\.conf$|opencode\.key'

# 2) 确认忽略规则生效
git status --ignored --short | grep -E '^!!' | head -20

# 3) 扫一遍将要提交的内容里有没有裸密钥特征
git diff --cached | grep -nE 'oc_sk_|SECRET *= *"[0-9a-f]{16,}|password *= *"[^"]{4,}"'

# 4) 扫一遍有没有设备标识
git diff --cached | grep -nE '\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b|[0-9a-f]{4}:[0-9a-f]{4}:'
```

CI（`.gitlab-ci.yml` 的 `secret-scan` 段）会自动跑第 3 条。

## 5. 几条硬规矩

1. **不要**把凭据写进源码、文档、示例、日志、提交信息。
2. **不要**把设备标识写进本仓的任何文件。
3. 发现明文凭据**当作缺陷报**（见 [../SECURITY.md](../SECURITY.md)），
   **不要在公开 Issue 里贴出凭据本身**。
4. 凭据一旦泄露，**删掉明文不等于失效** —— 要去设备上轮换。

## 6. 相关文档

- [../AGENTS.md](../AGENTS.md) §2 —— 设备相关的值一律外置（机器可读版）
- [../CONTRIBUTING.md](../CONTRIBUTING.md) —— 硬规矩与提交前自检
- [MAINTENANCE.md](MAINTENANCE.md) —— 设备配置模板怎么随版本升级
