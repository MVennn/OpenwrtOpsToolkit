# 参与贡献

> **一句话**：怎么把东西跑起来、改代码守什么规矩、提交前跑什么。

## 跑起来

```sh
# 设备配置：复制样例后按自己的环境改
cp openwrt/conf/device.conf.example openwrt/conf/device.conf

# 诊断类工具（只读）
python3 mihomo/rule_audit.py --help
MIHOMO_API=http://127.0.0.1:9999 MIHOMO_SECRET=xxx python3 mihomo/latency_probe.py

# 设备侧脚本：先干跑
sh openwrt/guardian.sh --dry-run
sh openwrt/recover-now.sh --check
```

> `openwrt/` 的脚本**会改设备状态**。装到路由器之前先读
> [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) 的「会改什么」。

## 硬规矩

### 1. 设备相关的值一律外置

**不许**把下面这些写进源码、文档、示例、日志：

| 类别 | 例子 | 该放哪 |
|---|---|---|
| 节点名 | 某个具体国家的节点 | `openwrt/conf/device.conf` |
| 策略组名 | 某个具体的组 | 同上 |
| 设备标识 | MAC / IPv6 PD / WiFi SSID / 运营商地址 | 哪都不该放 |
| 凭据 | 口令 / API key / secret | 环境变量 |
| 本机绝对路径 | 你的家目录 | 相对路径或 `~` 推导 |

脚本读取顺序：**环境变量 → `device.conf` → 占位符默认值**。

**占位符写法**：`<REDACTED-...>`（凭据）、`<REPLACE-...>`（需要你自己填的值）。

### 2. 逻辑不要动

改脚本时**只改「值从哪来」**，不要顺手重构逻辑 —— 这些脚本在真实设备上跑着，
行为变更需要真机验证。

### 3. 格式

- shell 脚本**必须 LF 换行** —— CRLF 在 busybox 下直接报 `bad interpreter`。
- Python 只用标准库（本仓不引第三方依赖，保持 `git clone` 就能跑）。
- 不要动 `third-party/`（vendored 上游，一个字节都不动）。

## 文档

规则见 [docs/DOC-RULES.md](docs/DOC-RULES.md)（单一正本、每篇开头一句话引言块、
索引唯一、孤儿零容忍）。改完跑：

```bash
python3 tools/check-docs.py
```

## 提交前自检

```bash
# shell 语法
for f in $(find openwrt -name '*.sh'); do sh -n "$f"; done

# python 语法
python3 -c "import ast,glob; [ast.parse(open(f,encoding='utf-8').read(), f) for f in glob.glob('**/*.py', recursive=True)]"

# 文档
python3 tools/check-docs.py
```

CI（`.gitlab-ci.yml`）跑的就是这三样，外加一条**明文凭据扫描**。

## 提交信息

Conventional Commits：`feat:` `fix:` `docs:` `chore:` `refactor:` `test:` `perf:`。
多个改动**按对象拆行**（一行一个对象），不要打包成"代码整理"。
