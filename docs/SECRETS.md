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

CI（`.github/workflows/ci.yml`）的凭据扫描步骤会自动跑第 3 条。

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

---

# 推送前脱敏规则（通用）

> **一句话**：推送前跑一次 `python tools/check-secrets.py`；它拦的是三类东西 ——
> 可用凭据、本机用户目录、真实邮箱。规则对 8 个仓完全一致，一处改全局同步。

---

## 1. 为什么需要这一条

历史教训：本系列仓的脱敏一度靠人记，结果漏过两次 ——

1. **同步脚本把 `--config` 的绝对路径回显进报告**，报告又作为 evidence 提交，
   本机用户目录就这样进了版本库。脚本默认值是按主目录推导的，本身没问题，
   问题出在那两行 `log("已写入 %s" % args.config)`。
2. **没有守卫的仓全靠自觉**。8 个仓里原本只有 2 个有 `tools/check-secrets.py`，
   规则里还不含本机路径。

所以规则固化成本篇 + 一个脚本 + 一个 CI 步骤。脚本是规则的**可执行版本**。

---

## 2. 三类拦截面

| 类别 | 例子 | 为什么拦 |
|---|---|---|
| **P0 可用凭据** | `gh[pousr]_…`、`sk-…`、`oc_sk_…`、`AIza…`、`glpat-…`、`-----BEGIN … PRIVATE KEY`、`AKIA…`、shadow 哈希、订阅 URL 的 token 段、代理节点 URI | 任何人拿到就能直接用 |
| **P1 本机用户目录** | `C:\Users\<名字>\…`（正反斜杠都拦） | 暴露用户名与软件安装布局，是社工的素材 |
| **P1 真实邮箱** | `…@qq.com` / `@163.com` / `@gmail.com` 等 | 暴露个人身份；GitHub noreply 邮箱不含这些域名，不会误伤 |

> **域名清单**：qq / 163 / 126 / gmail / outlook / hotmail / foxmail / sina / sohu。
> 只列国内常用与 Google / Microsoft 系 —— 加更多域名只会增加误报。

---

## 3. 三条放行规则（避免误报）

守卫不是越严越好，误报多了人就学会跳过它。所以明确放行三种情形：

### 3.1 占位符与示例值不算命中

行内含 `REDACTED` / `YOUR-` / `REPLACE-` / `<…>` / `example.com` / `placeholder`
/ `<用户名>` 等字样时，整行跳过。所以写文档时**优先用占位符**，能省掉很多例外。

### 3.2 文档类文件允许「截断形式」的描述性引用

变更说明里需要引用泄漏原文，否则读者不知道该改什么。形如下面的写法放行：

- 用户名位置就是省略号：`C:\Users\...\provider_config.json`
- 用户名用尖括号占位：`C:\Users\<名字>\...`
- 用户名后紧跟 `\...` 截断：`C:\Users\SansK\...`

**完整路径一律不放行。** 这条只对文档类文件生效
（`CHANGELOG.md` / `PROGRESS.md` / `SECURITY.md` / `CONTRIBUTING.md` / `docs/` /
`evidence/` / `memories/`）。

### 3.3 占位用户名不算命中

示例文件里的 `C:/Users/You/...`、`C:/Users/User/...`、`C:/Users/你的用户名/...`
是给用户照着改的模板，不是本机路径。

---

## 4. 白名单：只放「有意为之」

逐行白名单（`LINE_ALLOWLIST`）只放两类情形，**每条必须写清理由**：

- **机制上就该出现** —— 如 `.mailmap` 里的邮箱映射，那是 git 官方的作者身份
  归属机制，邮箱本来就该在里面。
- **确定不是敏感信息** —— 如 Kotlin 协程符号 `$scaleDone$1` 被 shadow 哈希
  正则误判。

加白名单前先问：能不能改用占位符绕开？能的话优先改内容，不要加白名单。

---

## 5. 推送前怎么做

```sh
# 1) 扫已跟踪文件（CI 跑的就是这个，退出码 0 才能推）
python tools/check-secrets.py

# 2) 扫工作树，含未跟踪文件（提交前自查用）
python tools/check-secrets.py --all
```

`--all` 模式**遵循 `.gitignore`** —— 本机配置（如 `config.local.json`）设计上
就不入库，报出来只是噪音。但它仍会扫**未跟踪且未被忽略**的新文件，所以能抓住
「新建了个文件忘了加 .gitignore」这种情况。

**CI 里有「敏感信息扫描」步骤**，推上去会自动跑。本地先跑一遍，别等 CI 报错。

---

## 6. 踩过的坑（写规则/脚本时注意）

1. **Python 单元素元组**：`SKIP_PREFIXES = ("tools/preview/")` 少了尾逗号，
   它不是元组而是字符串，`any(base.startswith(p) for p in "…")` 会逐字符迭代，
   导致所有以首字符开头的路径都被跳过 —— 守卫静默失效，扫描显示"通过"但实际
   什么都没查。必须写 `("tools/preview/",)`。
2. **`printf` 吞转义**：Git Bash 里 `printf 'C:\Users\...'` 把 `\U` 当 unicode
   转义，写出的测试文件内容是坏的，注入测试假通过。写含反斜杠的测试内容要用
   Python 的 `chr(92)`。
3. **replace-text 只匹配字面量**：重写历史时，文档里引用泄漏原文的写法
   （如 `git grep Users.SansK`，没有 `C:\` 前缀）匹配不到，要单独列规则。
4. **模板多行块替换**：按单行字符串替换跨多行的配置块会留下孤儿行导致
   IndentationError；先在源里 `assert` 锚点存在再替换，失败即中止。
5. **守卫脚本自己的注释会被自己的规则拦到** —— 注释里别出现完整路径字面量。

---

## 7. 相关文档

| 要查什么 | 去哪 |
|---|---|
| 凭据从哪读、怎么轮换 | 本篇其余章节 |
| 上报安全问题 | [../SECURITY.md](../SECURITY.md) |
| 提交前自检 | [../CONTRIBUTING.md](../CONTRIBUTING.md) |
| 文档怎么写 | [DOC-RULES.md](DOC-RULES.md) |
