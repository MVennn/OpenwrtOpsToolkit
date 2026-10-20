# OpenwrtOpsToolkit —— 记忆索引

> **一句话**：本工具箱的**记忆文档** —— 踩过的坑、根因、实测结论。
>
> 同样内容也存在于 ZCode 的记忆库（按项目 id 分目录），这里是**随 git 版本化的快照**。
> 一条一件事，文件名 kebab-case；敏感值写 `<REDACTED-...>` 占位符。

- [redir-mode-udp-quic-leak](redir-mode-udp-quic-leak.md) — OpenWrt 透明代理(Redir)模式下 UDP 全部绕过代理，浏览器 QUIC 直出带国内 IP，导致网页外壳能开但 UI 加载不全
- [router-offline-recovery](router-offline-recovery.md) — 路由器「连上 WiFi 但没网」的离线恢复配方（先摘 DNS 劫持恢复直连再修代理），以及助手在用户 PC 上远程操作路由器时必须写成
- [shellcrash-rule-reorg](shellcrash-rule-reorg.md) — ShellCrash 规则重组：rules.yaml 三层结构、分类修正层顺序约束、rules-mid CN 中间层，含验证结果与已知坑

共 3 条。新增记忆时：一条一文件，写完把上面索引补一行。
