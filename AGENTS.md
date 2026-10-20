# AGENTS —— 机器协议

> **一句话**：三条硬规矩 —— **PROGRESS 按逻辑任务分家**、**设备相关的值一律外置**、
> **有 CodeGraph 就先用 CodeGraph**。其它都能从 [docs/](docs/README.md) 里查到。

---

## 1. PROGRESS：路径由逻辑任务决定，不是物理目录

- 每个逻辑任务目录内有**且仅有一个** `PROGRESS.md`（追加式批次日志）。
- 子代理**只写自己的分片文件**（`evidence/agent-<name>.md` 这类），
  **绝不写任何共享文件** —— 历史上 13 个并行子代理互相覆盖过同一个 PROGRESS。
- 分片写完同步根 `PROGRESS.md`。

## 2. 设备相关的值一律外置

**不许把下面这些写进源码、文档、示例、日志**：

| 类别 | 例子 | 该放哪 |
|---|---|---|
| 节点名 | `某个具体节点的显示名` | `openwrt/conf/device.conf` |
| 策略组名 | `某个具体策略组的显示名` | 同上 |
| 设备标识 | MAC / IPv6 PD / WiFi SSID / 运营商地址 | 哪都不该放 |
| 凭据 | 口令 / API key / secret | 环境变量 |
| 本机绝对路径 | `C:\Users\<你>` / `/home/<你>` | 相对路径或 `~` 推导 |

**占位符写法**：`<REDACTED-...>`（凭据）、`<REPLACE-...>`（需要你自己填的值）。

`openwrt/` 下的脚本读取顺序：**环境变量 → `device.conf` → 占位符默认值**。
`DEVICE_CONF` 环境变量可指定配置文件路径。

## 3. CodeGraph

仓库根有 `.codegraph/` 时，**先 `codegraph_explore` 找代码，再 grep**。
没有就跳过 —— 别为此手动建索引。

```bash
codegraph explore "guardian.sh 巡检逻辑"
```

---

## 其他约定（详见 docs/DOC-RULES.md）

- 每篇文档开头必须有 `> **一句话**：…` 引言块。
- 相对链接 + 半角括号；改文档后跑 `python3 tools/check-docs.py`。
- shell 脚本**必须 LF 换行** —— CRLF 在 busybox 下直接报错。
- 提交信息用 Conventional Commits，**按对象拆行**。
- 不要动 `third-party/`（vendored 上游，一个字节都不动）。
