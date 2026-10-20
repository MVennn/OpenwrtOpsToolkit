#!/bin/sh
# recover-now.sh —— ShellCrash / mihomo 离线恢复（DNS 解析全失败、代理离线）
#
# 触发场景：fake-ip 过滤文件里出现空行 → ShellCrash 把它原样塞进 fake-ip-filter
#           → mihomo DNS 异常/不自愈 → 内网所有域名解析失败
#           → 客户端表现为「WiFi 连上了但没网」
#
# 用法：  sh recover-now.sh           完整修复
#         sh recover-now.sh check     只诊断，不改任何东西
# 日志：  $RECOVER_LOG（默认 /root/recover-last.log，overlay 持久化，重启不丢）
#
# 所有设备相关的值（路径、端口、表名、策略组名）都来自配置，
# 见 conf/device.conf.example。脚本本身不含任何设备标识。

# ---------------------------------------------------------------------------
# 配置加载：环境变量 > device.conf > 本文件里的默认值
# ---------------------------------------------------------------------------
OPS_CONF="${DEVICE_CONF:-}"
if [ -z "$OPS_CONF" ]; then
  OPS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
  [ -n "$OPS_DIR" ] || OPS_DIR="."
  for _c in "$OPS_DIR/conf/device.conf" /etc/openwrt-ops/device.conf; do
    if [ -f "$_c" ]; then OPS_CONF="$_c"; break; fi
  done
fi

_OPS_VARS="CRASHDIR RUNTIME_DIR MIXED_PORT DNS_PORT CTRL_PORT PROXY_PORT CORE_PROC NFT_DIR NFT_TABLES CRON_FILE RC_LOCAL GUARDIAN_PATH LEGACY_WD API_CFG RECOVER_LOG DNS_HIJACK_TABLES CLEAN_GROUP DIRECT_TEST_HOST PROXY_TEST_URL PROXY_TEST_URL2"
_OPS_SNAP=""
for _v in $_OPS_VARS; do
  eval "[ \"\${${_v}+set}\" = set ]" || continue
  eval "_O_SNAP_${_v}=\$(printf '%s' \"\${${_v}-}\")"
  _OPS_SNAP="$_OPS_SNAP $_v"
done
if [ -n "$OPS_CONF" ] && [ -f "$OPS_CONF" ]; then
  if sh -n "$OPS_CONF" 2>/dev/null; then
    . "$OPS_CONF" 2>/dev/null
  else
    echo "警告：配置文件 $OPS_CONF 语法错误，已忽略（走默认值）" >&2
  fi
fi
for _v in $_OPS_SNAP; do
  eval "${_v}=\$(printf '%s' \"\${_O_SNAP_${_v}-}\")"
done

# ---------------------------------------------------------------------------
# 默认值
# ---------------------------------------------------------------------------
CRASHDIR="${CRASHDIR:-/etc/ShellCrash}"
RUNTIME_DIR="${RUNTIME_DIR:-/tmp/ShellCrash}"
MIXED_PORT="${MIXED_PORT:-7892}"
DNS_PORT="${DNS_PORT:-1053}"
PROXY_PORT="${PROXY_PORT:-7890}"
CTRL_PORT="${CTRL_PORT:-9999}"
CORE_PROC="${CORE_PROC:-CrashCore}"
NFT_DIR="${NFT_DIR:-/etc}"
NFT_TABLES="${NFT_TABLES:-quicguard googlecn googleroute}"
CRON_FILE="${CRON_FILE:-/etc/crontabs/root}"
RC_LOCAL="${RC_LOCAL:-/etc/rc.local}"
GUARDIAN_PATH="${GUARDIAN_PATH:-$CRASHDIR/guardian.sh}"
LEGACY_WD="${LEGACY_WD:-$CRASHDIR/starts/start_legacy_wd.sh}"
RECOVER_LOG="${RECOVER_LOG:-/root/recover-last.log}"
DNS_HIJACK_TABLES="${DNS_HIJACK_TABLES:-inet googleroute inet shellcrash ip shellcrash ip6 shellcrash}"
CLEAN_GROUP="${CLEAN_GROUP:-}"
DIRECT_TEST_HOST="${DIRECT_TEST_HOST:-www.baidu.com}"
PROXY_TEST_URL="${PROXY_TEST_URL:-https://www.google.com}"
PROXY_TEST_URL2="${PROXY_TEST_URL2:-https://gemini.google.com/}"

MODE="${1:-fix}"
LOG="$RECOVER_LOG"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
section() { log ""; log "=============================="; log "$*"; log "=============================="; }
run() { log "\$ $*"; "$@" 2>&1 | tee -a "$LOG"; }

core_up() {
    pidof "$CORE_PROC" >/dev/null 2>&1 && netstat -lntp 2>/dev/null | grep -q ":$MIXED_PORT"
}
dns_up() {
    netstat -lntp 2>/dev/null | grep -q ":$DNS_PORT"
}

section "0. 环境 $(date)"
log "mode=$MODE"
run uptime
run df -h /tmp /overlay

section "1. 修复 fake-ip 过滤文件（去掉空行/注释/重复项）"
FIP="$CRASHDIR/configs/fake_ip_filter"
if [ -f "$FIP" ]; then
    cp -f "$FIP" "$(dirname "$FIP")/fake_ip_filter.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null
    log "改前行数=$(wc -l < "$FIP")  空行数=$(grep -c '^[[:space:]]*$' "$FIP")"
    grep -v '^[[:space:]]*$' "$FIP" | grep -v '^[[:space:]]*#' | sed 's/[[:space:]]*$//' | awk '!a[$0]++' > "$FIP.tmp"
    mv -f "$FIP.tmp" "$FIP"
    log "改后行数=$(wc -l < "$FIP")"
    log "-- 过滤清单 --"
    cat "$FIP" | tee -a "$LOG"
else
    log "!! $FIP 不存在"
fi

if [ "$MODE" = "check" ]; then
    section "2. 当前状态（check 模式，不做任何修改）"
    run pidof "$CORE_PROC"
    log "$MIXED_PORT 端口: $(netstat -lntp 2>/dev/null | grep -c ":$MIXED_PORT")"
    log "$DNS_PORT DNS 端口: $(netstat -lntp 2>/dev/null | grep -c ":$DNS_PORT")"
    run nft list tables
    log "-- 内网解析测试 --"
    run nslookup "$DIRECT_TEST_HOST" 127.0.0.1
    log "日志：$LOG"
    exit 0
fi

section "2. 先摘掉 DNS 劫持，让内网直连立刻恢复（此时外网不走代理）"
for t in $DNS_HIJACK_TABLES; do
    [ -z "$t" ] && continue
    if nft list table $t >/dev/null 2>&1; then
        nft delete table $t 2>/dev/null && log "已删除 nft 表：$t"
    fi
done
/etc/init.d/dnsmasq restart >/dev/null 2>&1 && log "dnsmasq 已重启（内网 DNS 回到直连解析）"
sleep 2
log "-- 直连测试 --"
run nslookup "$DIRECT_TEST_HOST" 127.0.0.1

section "3. 停核心、清理运行态配置，重新生成"
[ -f "$CRON_FILE" ] && cp -f "$CRON_FILE" /tmp/cron.recover.bak
sh "$CRASHDIR/start.sh" stop >/dev/null 2>&1
killall -9 "$CORE_PROC" 2>/dev/null
sleep 1
mkdir -p "$RUNTIME_DIR"
rm -f "$RUNTIME_DIR/config.yaml" "$RUNTIME_DIR/error.yaml" "$RUNTIME_DIR/shellcrash.pid"
log "运行态配置已清空，交给 start.sh 重新生成"
sh "$CRASHDIR/start.sh" start 2>&1 | tail -30 | tee -a "$LOG"
i=0
while [ $i -lt 30 ]; do
    core_up && break
    sleep 1
    i=$((i+1))
done
core_up && log "$CORE_PROC 已就绪" || log "!! 30 秒内核心未就绪"

section "4. 加载自建 nft 表（DNS 劫持 / QUIC 拦截 / 直连分流）"
for t in $NFT_TABLES; do
    [ -z "$t" ] && continue
    if [ -f "$NFT_DIR/$t.nft" ]; then
        nft -f "$NFT_DIR/$t.nft" >/dev/null 2>&1 && log "已加载 inet $t" || log "!! inet $t 加载失败"
    else
        log "!! $NFT_DIR/$t.nft 不存在"
    fi
done
FIRST_T=$(echo "$NFT_TABLES" | awk '{print $1}')
[ -n "$FIRST_T" ] && { grep -q "$FIRST_T" "$RC_LOCAL" 2>/dev/null || log "提醒：$RC_LOCAL 里没有 $FIRST_T 的开机加载"; }

section "4.1 重载 fw4 防火墙（start.sh 可能把它留在半加载状态，表现为连上却没网）"
/etc/init.d/firewall restart 2>&1 | tail -5 | tee -a "$LOG"
sleep 3
log "-- WAN 口地址与默认路由 --"
ip -brief addr show 2>/dev/null | grep -E 'wan|br-lan' | tee -a "$LOG"
ip route show default 2>/dev/null | tee -a "$LOG"
if ! ip -brief addr show 2>/dev/null | grep -q 'wan'; then
    log "!! WAN 口没有地址，尝试 ifup wan"
    ifup wan 2>&1 | tail -5 | tee -a "$LOG"
    sleep 5
    ip -brief addr show 2>/dev/null | grep -E 'wan|br-lan' | tee -a "$LOG"
fi
if ! ip route show default 2>/dev/null | grep -q .; then
    log "!! 没有默认路由，尝试 ifup wan"
    ifup wan >/dev/null 2>&1
    sleep 5
    ip route show default 2>/dev/null | tee -a "$LOG"
fi

section "5. 恢复看门狗 crontab"
if [ -f /tmp/cron.recover.bak ]; then
    crontab /tmp/cron.recover.bak 2>/dev/null && log "crontab 已恢复"
    if [ -n "$GUARDIAN_PATH" ]; then
        grep -q "$(basename "$GUARDIAN_PATH")" "$CRON_FILE" 2>/dev/null || {
            echo "*/5 * * * * /bin/ash $GUARDIAN_PATH #网络守护:出口组复原+nft表补载+探活" >> "$CRON_FILE"
            crontab "$CRON_FILE" 2>/dev/null && log "已补回 guardian 守护行"
        }
    fi
    if [ -n "$LEGACY_WD" ]; then
        grep -q "$(basename "$LEGACY_WD")" "$CRON_FILE" 2>/dev/null || {
            echo "* * * * * /bin/ash $LEGACY_WD shellcrash #ShellCrash保守模式守护进程" >> "$CRON_FILE"
            crontab "$CRON_FILE" 2>/dev/null && log "已补回 legacy 看门狗行"
        }
    fi
    run crontab -l
fi

section "6. 校验"
run pidof "$CORE_PROC"
log "$MIXED_PORT=$(netstat -lntp 2>/dev/null | grep -c ":$MIXED_PORT")  $DNS_PORT=$(netstat -lntp 2>/dev/null | grep -c ":$DNS_PORT")  $CTRL_PORT=$(netstat -lntp 2>/dev/null | grep -c ":$CTRL_PORT")"
run nft list tables
if [ -s "$RUNTIME_DIR/config.yaml" ]; then
    log "运行态 config.yaml = $(wc -c < "$RUNTIME_DIR/config.yaml") bytes"
    if [ -n "$CLEAN_GROUP" ]; then
        grep -q "$CLEAN_GROUP" "$RUNTIME_DIR/config.yaml" && log "自定义组（$CLEAN_GROUP）已加载" || log "!! 自定义组缺失（可能回退基础配置）"
    fi
else
    log "!! 运行态 config.yaml 不存在"
fi
ls -la "$RUNTIME_DIR/error.yaml" 2>/dev/null && log "!! 存在 error.yaml = 配置校验失败过（已回退基础配置）" || log "无 error.yaml（未回退）"

section "7. 连通性"
run nslookup "$DIRECT_TEST_HOST" 127.0.0.1
curl -s --max-time 10 -o /dev/null -w '  direct=%{http_code} %{time_total}s\n' "http://$DIRECT_TEST_HOST" 2>&1 | tee -a "$LOG"
if core_up; then
    curl -s --max-time 15 -x "http://127.0.0.1:$PROXY_PORT" -o /dev/null -w '  proxy=%{http_code} %{time_total}s\n' "$PROXY_TEST_URL" 2>&1 | tee -a "$LOG"
    curl -s --max-time 15 -x "http://127.0.0.1:$PROXY_PORT" -o /dev/null -w '  proxy2=%{http_code} %{time_total}s\n' "$PROXY_TEST_URL2" 2>&1 | tee -a "$LOG"
fi

section "完成"
log "日志：$LOG"
log "把上面输出发回即可继续排查"
