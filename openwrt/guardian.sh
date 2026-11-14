#!/bin/sh
# ============================================================================
# 网络守护 —— 只做「检测 + 最小化修复」，绝不做破坏性操作
#
# 原理：
#   1. 只在检测到偏离「已知良好状态」时才动手；每种修复都幂等、可回退
#   2. 绝不删改防火墙链、绝不重启路由器、绝不改订阅与规则文件
#   3. 关键动作失败必须显式报错
#   4. 维护前可先停守护：sed -i '/guardian/d' /etc/crontabs/root && /etc/init.d/cron restart
#
# 用法：
#   sh guardian.sh                          跑一轮
#   sh guardian.sh --dry-run                只检测、只报告，不做任何改动
#   sh guardian.sh --status                 只读体检：各组当前出口、内存与 /tmp 水位、nft 表，
#                                           不取实例锁、不写日志、不写状态文件
#   DEVICE_CONF=/etc/openwrt-ops/device.conf sh guardian.sh
#
# 机器可读状态：每轮收尾原子写 $RUNTIME_DIR/ops-guardian.state（多行 key=value，tmpfs，
# 不占闪存写入）。键名与 AX3000TOpenwrt 的 guardian.state 完全对齐，但**文件名分开**：
# 两版守护同时装在同一台设备上时，同名文件会被后写者覆盖，下游计数来回跳（P57）。
# 消费方 ops-status.sh 按 ops-guardian.state → guardian.state 的顺序探测。
#
# 所有「只对某一台机器成立」的值（策略组名、节点名、路径、端口、阈值）
# 全部来自配置，脚本本身不含任何设备标识 —— 见 conf/device.conf.example。
# ============================================================================

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

# 这些变量如果本来就在环境里，优先级高于 device.conf —— 先记住，载入后再还原
_OPS_VARS="CRASHDIR RUNTIME_DIR CTRL_HOST CTRL_PORT PROXY_PORT MIXED_PORT DNS_PORT CORE_PROC NFT_DIR NFT_TABLES CRON_FILE GUARDIAN_LOG START_SH TASK_SH LEGACY_WD API_CFG AI_GROUP AI_FALLBACK_GROUP CLEAN_GROUP CLEAN_NODE CL_CANDIDATES POOL_GROUP POOL_FALLBACK_GROUP MANUAL_GROUP AI_BAD_NODES POOL_BLOCKED_NODES PROBE_URL CLEAN_PROBE_URL CC_PROBE_URL CC_EXPECT EXIT_MAX_SEC CLEAN_EXIT_MAX_SEC MEM_LOW_MB TMPFS_WARN_PCT FALLBACK_HEAL_INTERVAL ALIVE_STALE_SEC TMPFS_CLEAN_FILES ROUTER_HEALTH_DIR GUARDIAN_STATE"
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
CTRL_HOST="${CTRL_HOST:-127.0.0.1}"
CTRL_PORT="${CTRL_PORT:-9999}"
PROXY_PORT="${PROXY_PORT:-7890}"
MIXED_PORT="${MIXED_PORT:-7892}"
DNS_PORT="${DNS_PORT:-1053}"
CORE_PROC="${CORE_PROC:-CrashCore}"
NFT_DIR="${NFT_DIR:-/etc}"
NFT_TABLES="${NFT_TABLES:-quicguard googleroute googlecn}"
CRON_FILE="${CRON_FILE:-/etc/crontabs/root}"
GUARDIAN_LOG="${GUARDIAN_LOG:-$RUNTIME_DIR/guardian.log}"
# 机器可读状态文件（tmpfs）：与 AX3000TOpenwrt 的 guardian.state 同键名同格式，
# 见文件头「机器可读状态」与 docs/ARCHITECTURE.md §4.2。
GUARDIAN_STATE="${GUARDIAN_STATE:-$RUNTIME_DIR/ops-guardian.state}"
START_SH="${START_SH:-$CRASHDIR/start.sh}"
TASK_SH="${TASK_SH:-$CRASHDIR/task/task.sh}"
LEGACY_WD="${LEGACY_WD:-$CRASHDIR/starts/start_legacy_wd.sh}"
API_CFG="${API_CFG:-$CRASHDIR/configs/ShellCrash.cfg}"

# 策略组与节点（留空 = 相关动作跳过）
AI_GROUP="${AI_GROUP:-}"
AI_FALLBACK_GROUP="${AI_FALLBACK_GROUP:-}"
CLEAN_GROUP="${CLEAN_GROUP:-}"
CLEAN_NODE="${CLEAN_NODE:-}"
CL_CANDIDATES="${CL_CANDIDATES:-}"
POOL_GROUP="${POOL_GROUP:-}"
POOL_FALLBACK_GROUP="${POOL_FALLBACK_GROUP:-}"
MANUAL_GROUP="${MANUAL_GROUP:-}"
AI_BAD_NODES="${AI_BAD_NODES:-}"
POOL_BLOCKED_NODES="${POOL_BLOCKED_NODES:-}"

# 探测
PROBE_URL="${PROBE_URL:-https://api.ipify.org}"
CLEAN_PROBE_URL="${CLEAN_PROBE_URL:-https://gemini.google.com/}"
CC_PROBE_URL="${CC_PROBE_URL:-https://support.google.com/gemini/answer/13575153}"
CC_EXPECT="${CC_EXPECT:-}"
EXIT_MAX_SEC="${EXIT_MAX_SEC:-3}"
CLEAN_EXIT_MAX_SEC="${CLEAN_EXIT_MAX_SEC:-4}"

# 阈值
MEM_LOW_MB="${MEM_LOW_MB:-30}"
TMPFS_WARN_PCT="${TMPFS_WARN_PCT:-80}"
FALLBACK_HEAL_INTERVAL="${FALLBACK_HEAL_INTERVAL:-1800}"
ALIVE_STALE_SEC="${ALIVE_STALE_SEC:-1800}"
TMPFS_CLEAN_FILES="${TMPFS_CLEAN_FILES:-/tmp/pre-reboot-config.tar.gz /tmp/mihomo-new /tmp/mihomo-arm64.gz /tmp/core_test_out.txt}"

# ---------------------------------------------------------------------------
# 运行时
# ---------------------------------------------------------------------------
# 三种模式：run（默认）/ dry（干跑：只检测、只报告，不改设备任何状态）/
# status（只读体检：不取锁、不写日志、不写状态文件，可与 cron 里的守护同时跑）
DRY_RUN="${DRY_RUN:-0}"
MODE=run
case "${1:-}" in
  --dry-run|-n) DRY_RUN=1; MODE=dry ;;
  --status) MODE=status ;;
  -h|--help) awk 'NR>1{ if(/^# =====/){ if(++n==2) exit; if(n==1) next } print }' "$0"; exit 0 ;;
  "") ;;
  *) echo "未知参数：$1（可用：--dry-run / --status / --help）" >&2; exit 2 ;;
esac

# --status 是只读体检：不建目录、不写日志，否则「只看一眼」也会在设备上留痕，
# 与 usage 承诺的「不改设备任何状态」相反。
if [ "$MODE" != "status" ]; then
  mkdir -p "$RUNTIME_DIR" 2>/dev/null
fi
LOG="$GUARDIAN_LOG"
if [ "$MODE" != "status" ]; then
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
fi
CURL="${CURL:-/usr/bin/curl}"
[ -x "$CURL" ] || CURL=curl
NFT="${NFT:-/usr/sbin/nft}"
[ -x "$NFT" ] || NFT=nft
CTRL="http://$CTRL_HOST:$CTRL_PORT"
PROXY="http://127.0.0.1:$PROXY_PORT"
PIDFILE="$RUNTIME_DIR/shellcrash.pid"
ALIVEF="$RUNTIME_DIR/.proxy_alive"
# 收尾要写进 guardian.state 的三个出口值：取本轮读到的 now，修复成功后改成目标组。
# 这样收尾写状态时不用再打控制 API（省 3 次往返、3 个 fork）。
ST_AI=""; ST_POOL=""; ST_CLEAN=""

# API secret 从设备上的配置现读，不写死在脚本里。
# shared:secret-read —— 与 bulk-guard.sh / traffic-stats.sh 逐字同一块，由
# tools/check-shell-shared-blocks.py 校验漂移（P35：守卫脚本逐仓复制会漂移）。
# tr -d '\r' 兜底：配置文件被 Windows 侧编辑过、或 apk 升级写成 CRLF 时，
# secret 尾部会带 \r，症状是控制 API 静默 401/无响应，极难查。
# >>> shared:secret-read >>>
API_SECRET=$(sed -n 's/^secret=//p' "$API_CFG" 2>/dev/null | head -1 | tr -d '\r')
# <<< shared:secret-read <<<
SECRET="$API_SECRET"
AUTH="Authorization: Bearer $SECRET"

# 每轮动作计数：收尾写进 guardian.state，排查时不用再 tail 日志拼「这轮修了什么」。
FIXES=0; ERRORS=0; WARNS=0; WOULDFIX=0; ALERTS=0
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() {
  case "$*" in
    FIX:*) FIXES=$((FIXES + 1)) ;;
    ERROR:*) ERRORS=$((ERRORS + 1)) ;;
    ALERT:*) ALERTS=$((ALERTS + 1)) ;;
    WARN:*) WARNS=$((WARNS + 1)) ;;
    DRY-RUN:*) WOULDFIX=$((WOULDFIX + 1)) ;;
  esac
  echo "$(ts) $*" >> "$LOG"
  case "$*" in
    *FIX*|*ALERT*|*ERROR*|*WARN*) logger -t guardian -p daemon.warn "$*" 2>/dev/null ;;
  esac
}
# 策略组名进 URL 路径必须转义 % 空格 # ? &（P33）
# >>> shared:enc >>>
enc() { printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/#/%23/g' -e 's/?/%3F/g' -e 's/&/%26/g'; }
# <<< shared:enc <<<
# >>> shared:json-esc >>>
json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
# <<< shared:json-esc <<<
# 从 /proxies 响应里取一个字段（now / fixed）：单次 awk 取第一个匹配。
# 原来 grep -oE|head|sed 三个进程，一轮要调 8–10 次，等于白扔 16–20 个 fork。
# >>> shared:api-field >>>
api_field() {
  awk -v f="$1" 'BEGIN{k="\"" f "\":\""; n=length(k)}
    {p=index($0,k); if(p){s=substr($0,p+n); q=index(s,"\""); print substr(s,1,q-1); exit}}'
}
# <<< shared:api-field <<<
grp() { $CURL -s -m 5 -H "$AUTH" "$CTRL/proxies/$(enc "$1")" 2>/dev/null | api_field now; }
# 切组：DRY_RUN 只回显不动作；正常路径回 HTTP 状态码
# >>> shared:put >>>
put() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN: 将把「$1」切到「$2」"
    echo 204
    return 0
  fi
  $CURL -s -m 8 -o /dev/null -w "%{http_code}" -H "$AUTH" \
    -X PUT "$CTRL/proxies/$(enc "$1")" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$(json_esc "$2")\"}" 2>/dev/null
}
# <<< shared:put <<<
[ -z "$API_SECRET" ] && log "ERROR: 未从 $API_CFG 读到 secret，本轮控制 API 动作将全部失效"

# 同一时间只允许一个实例：3.6 逐个候选探测最坏要跑两分多钟，加上 3.5 与第 1 节
# 的等待，整轮可能超过 cron 的 5 分钟；叠轮会让两轮同时切策略组、同时写
# .clean_node / .clean_verdict，日志记录与实际生效节点对不上。
# 锁形状照抄 bulk-guard.sh：mkdir 原子建锁 + pid/ts + 过期回收 + trap 清理。
GUARDIAN_LOCK="$RUNTIME_DIR/guardian.lock"
acquire_lock() {
  _now=$(date +%s)
  if [ -d "$GUARDIAN_LOCK" ]; then
    _lp=$(cat "$GUARDIAN_LOCK/pid" 2>/dev/null)
    _lt=$(cat "$GUARDIAN_LOCK/ts" 2>/dev/null)
    case "$_lt" in ''|*[!0-9]*) _lt=0 ;; esac
    if [ -n "$_lp" ] && kill -0 "$_lp" 2>/dev/null && [ $((_now - _lt)) -lt 600 ]; then
      log "另一实例在跑（pid=$_lp），跳过本轮"
      exit 0
    fi
    rm -f "$GUARDIAN_LOCK/pid" "$GUARDIAN_LOCK/ts" 2>/dev/null
    rmdir "$GUARDIAN_LOCK" 2>/dev/null
  fi
  mkdir "$GUARDIAN_LOCK" 2>/dev/null || { log "无法取得实例锁，跳过本轮"; exit 0; }
  echo $$ > "$GUARDIAN_LOCK/pid"
  echo "$_now" > "$GUARDIAN_LOCK/ts"
  trap 'rm -f "$GUARDIAN_LOCK/pid" "$GUARDIAN_LOCK/ts" 2>/dev/null; rmdir "$GUARDIAN_LOCK" 2>/dev/null' EXIT INT TERM HUP
}
# 实例锁在函数定义之后才取：--status 是只读体检，绝不能占锁（否则会和 cron 里的
# 守护互相跳过一轮）。取锁点见下面 log_trim 之后。

# 通配匹配：$1 = 节点名，$2 = `|` 分隔的通配模式串；命中返回 0
match_patterns() {
  _mp_name=$1
  _mp_pats=$2
  [ -n "$_mp_pats" ] || return 1
  _mp_old="$IFS"
  IFS="|"
  for _mp_p in $_mp_pats; do
    [ -z "$_mp_p" ] && continue
    case "$_mp_name" in
      $_mp_p) IFS="$_mp_old"; return 0 ;;
    esac
  done
  IFS="$_mp_old"
  return 1
}

# 秒数比较：实际值 >= 阈值 时返回 0
ge_sec() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }

# 顺着「手动切换」组解析真实出口节点
eff_node() {
  n=$(grp "$1")
  [ -z "$n" ] && return 0
  if [ -n "$MANUAL_GROUP" ] && [ "$n" = "$MANUAL_GROUP" ]; then
    grp "$MANUAL_GROUP"
  else
    echo "$n"
  fi
}

# 日志自限容：日志在 tmpfs（P1/P17），超 200KB 截成最后 60 行。
# 临时名带 $$：锁过期叠轮时两个实例不会互踩同一个 $LOG.tmp。
# >>> shared:log-trim >>>
log_trim() {
  [ -f "$1" ] || return 0
  _lt_sz=$(wc -c < "$1" 2>/dev/null || echo 0)
  case "$_lt_sz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_lt_sz" -gt "${2:-204800}" ] || return 0
  tail -n "${3:-60}" "$1" > "$1.tmp.$$" 2>/dev/null && mv -f "$1.tmp.$$" "$1" || rm -f "$1.tmp.$$"
}
# <<< shared:log-trim <<<

# ---------- 只读体检（--status）----------
# 只打印现状：不取实例锁、不写日志、不写状态文件、不改任何设备状态。
status_report() {
  echo "== guardian 只读体检 =="
  echo "配置: ${OPS_CONF:-<无>}（环境变量 > device.conf > 内置默认）"
  echo "模式: $MODE（--dry-run 下所有动作只记录不执行）"
  if $CURL -s -m 5 -H "$AUTH" "$CTRL/version" >/dev/null 2>&1; then
    echo "核心: API 有响应（$CTRL/version）"
  elif pidof "$CORE_PROC" >/dev/null 2>&1; then
    echo "核心: 进程在但 API 无响应（$CORE_PROC，可能正在热重载）"
  else
    echo "核心: 进程不在（$CORE_PROC）"
  fi
  for _g in "$AI_GROUP" "$AI_FALLBACK_GROUP" "$CLEAN_GROUP" "$POOL_GROUP"; do
    [ -n "$_g" ] || continue
    _now=$(grp "$_g")
    if [ -z "$_now" ]; then
      echo "组「$_g」: 读不到（控制 API 无响应，或组名不在配置里）"
      continue
    fi
    _eff=$(eff_node "$_g")
    if [ -n "$MANUAL_GROUP" ] && [ "$_eff" != "$_now" ]; then
      echo "组「$_g」: now=「$_now」 生效=「$_eff」（经 $MANUAL_GROUP 解析）"
    else
      echo "组「$_g」: now=「$_now」"
    fi
  done
  _m=$(awk '/^MemAvailable/{a=$2} /^SwapFree/{s=$2}
            END{if(a==""){exit} printf "%d %d", a/1024, s/1024}' /proc/meminfo 2>/dev/null)
  if [ -n "$_m" ]; then
    _av=${_m%% *}; _sf=${_m##* }
    echo "内存: MemAvailable ${_av}MB + SwapFree/2 $((_sf / 2))MB = 宽松 $((_av + _sf / 2))MB（阈值 ${MEM_LOW_MB}MB）"
  else
    echo "内存: 读不到 /proc/meminfo"
  fi
  _d=$(df -k /tmp 2>/dev/null | awk 'END{print $3" "$2}')
  _u=${_d%% *}; _tk=${_d##* }
  if [ -n "$_u" ] && [ -n "$_tk" ] && [ "$_tk" -gt 0 ] 2>/dev/null; then
    echo "/tmp: $((_u * 100 / _tk))%（${_u}K/${_tk}K，阈值 ${TMPFS_WARN_PCT}%）"
  else
    echo "/tmp: 读不到 df"
  fi
  for _nt in $NFT_TABLES; do
    [ -z "$_nt" ] && continue
    if $NFT list table inet "$_nt" >/dev/null 2>&1; then
      echo "nft 表 inet $_nt: 在位"
    elif [ -f "$NFT_DIR/$_nt.nft" ]; then
      echo "nft 表 inet $_nt: 缺失（可从 $NFT_DIR/$_nt.nft 重载）"
    else
      echo "nft 表 inet $_nt: 缺失且 $NFT_DIR/$_nt.nft 不存在"
    fi
  done
  if [ -d "$GUARDIAN_LOCK" ]; then
    echo "实例锁: 占用中（pid=$(cat "$GUARDIAN_LOCK/pid" 2>/dev/null)，ts=$(cat "$GUARDIAN_LOCK/ts" 2>/dev/null)）"
  else
    echo "实例锁: 空闲"
  fi
  if [ -f "$GUARDIAN_STATE" ]; then
    echo "上一轮状态（$GUARDIAN_STATE）:"
    sed -e 's/^/  /' "$GUARDIAN_STATE" 2>/dev/null
  else
    echo "上一轮状态: 还没有（$GUARDIAN_STATE 不存在，守护没跑过）"
  fi
  echo "日志: $LOG（$(wc -c < "$LOG" 2>/dev/null || echo 0)B）"
}

# --status 必须在取锁之前退出：否则会和 cron 里的守护互相跳过一轮。
if [ "$MODE" = "status" ]; then
  status_report
  exit 0
fi

log_trim "$LOG"
acquire_lock

# ---------- 1) 核心存活（OOM 会被内核杀掉；服务关闭会清 pid 文件，故用「最近活着」状态文件兜底） ----------
if $CURL -s -m 5 -H "$AUTH" "$CTRL/version" >/dev/null 2>&1; then
  date +%s > "$ALIVEF" 2>/dev/null
else
  if pidof "$CORE_PROC" >/dev/null 2>&1; then
    log "WARN: $CORE_PROC 进程在但 API 无响应（可能正在热重载），本次不动作"
  else
    LAST=$(cat "$ALIVEF" 2>/dev/null || echo 0)
    NOWT=$(date +%s)
    if [ -f "$PIDFILE" ] || [ $((NOWT - LAST)) -lt "$ALIVE_STALE_SEC" ]; then
      if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: $CORE_PROC 进程不存在，本应调用 start.sh 拉起"
      else
        log "ALERT: $CORE_PROC 进程不存在（可能是 OOM 被杀），用 start.sh 拉起"
        /bin/ash "$START_SH" start >> "$LOG" 2>&1
        sleep 12
        if $CURL -s -m 5 -H "$AUTH" "$CTRL/version" >/dev/null 2>&1; then
          log "FIX: $CORE_PROC 已恢复"
        else
          log "ERROR: $CORE_PROC 拉起后仍无响应，需人工介入"
        fi
      fi
    else
      log "INFO: $CORE_PROC 已停止且近期无存活记录（判定为人为停止），守护不做拉起，不妨碍维护"
    fi
  fi
fi

# ---------- 2) AI 组出口必须干净 ----------
if [ -n "$AI_GROUP" ] && [ -n "$AI_FALLBACK_GROUP" ] && [ -n "$AI_BAD_NODES" ]; then
  AI_NOW=$(grp "$AI_GROUP")
  ST_AI="$AI_NOW"
  if [ -n "$AI_NOW" ]; then
    AI_EFF=$(eff_node "$AI_GROUP")
    if match_patterns "$AI_EFF" "$AI_BAD_NODES"; then
      if [ "$(put "$AI_GROUP" "$AI_FALLBACK_GROUP")" = "204" ]; then
        log "FIX: $AI_GROUP 从「$AI_NOW」(实际出口「$AI_EFF」) 复原为「$AI_FALLBACK_GROUP」（该出口不可信）"
        ST_AI="$AI_FALLBACK_GROUP"
      else
        log "ERROR: 切回 $AI_FALLBACK_GROUP 失败（控制 API 拒绝）"
      fi
    fi
  fi
fi

# ---------- 2.1) 兜底组 / 干净出口组 锁到唯一干净节点 ----------
if [ -n "$CLEAN_NODE" ] && [ -n "$AI_BAD_NODES" ]; then
  for g in "$AI_FALLBACK_GROUP" "$CLEAN_GROUP"; do
    [ -n "$g" ] || continue
    NOW=$(grp "$g")
    if [ -n "$NOW" ] && [ "$NOW" != "$CLEAN_NODE" ] && match_patterns "$NOW" "$AI_BAD_NODES"; then
      if [ "$(put "$g" "$CLEAN_NODE")" = "204" ]; then
        log "FIX: $g 从「$NOW」切到干净出口「$CLEAN_NODE」"
        [ "$g" = "$CLEAN_GROUP" ] && ST_CLEAN="$CLEAN_NODE"
      else
        log "ERROR: $g 切到 $CLEAN_NODE 失败"
      fi
    fi
  done
fi

# ---------- 2.2) 兜底组与干净出口组必须用同一个入口 ----------
# 两者通常指向同一批干净节点，但组成员会各自漂移；对齐入口只改链路、不改出口。
if [ -n "$CLEAN_GROUP" ] && [ -n "$AI_FALLBACK_GROUP" ]; then
  CL_NOW=$(grp "$CLEAN_GROUP")
  ST_CLEAN="$CL_NOW"
  AW_NOW=$(grp "$AI_FALLBACK_GROUP")
  if [ -n "$CL_NOW" ] && [ -n "$AW_NOW" ] && [ "$CL_NOW" != "$AW_NOW" ]; then
    if [ "$(put "$AI_FALLBACK_GROUP" "$CL_NOW")" = "204" ]; then
      log "FIX: $AI_FALLBACK_GROUP 入口「$AW_NOW」与 $CLEAN_GROUP「$CL_NOW」不一致，已对齐"
    else
      log "ERROR: $AI_FALLBACK_GROUP 对齐失败（控制 API 拒绝）"
    fi
  fi
fi

# ---------- 3) 通用池：只有落在不可用清单里才复位 ----------
if [ -n "$POOL_GROUP" ] && [ -n "$POOL_FALLBACK_GROUP" ] && [ -n "$POOL_BLOCKED_NODES" ]; then
  NODE_NOW=$(grp "$POOL_GROUP")
  ST_POOL="$NODE_NOW"
  if [ -n "$NODE_NOW" ]; then
    NODE_EFF=$(eff_node "$POOL_GROUP")
    if match_patterns "$NODE_EFF" "$POOL_BLOCKED_NODES"; then
      if [ "$(put "$POOL_GROUP" "$POOL_FALLBACK_GROUP")" = "204" ]; then
        log "FIX: $POOL_GROUP 从「$NODE_NOW」(实际出口「$NODE_EFF」) 复原为「$POOL_FALLBACK_GROUP」"
        ST_POOL="$POOL_FALLBACK_GROUP"
      else
        log "ERROR: 切回 $POOL_FALLBACK_GROUP 失败（控制 API 拒绝）"
      fi
    fi
  fi
fi

# ---------- 3.5) 通用出口健康守卫 ----------
# 节点会劣化（表现为全站超时）。按真实出口耗时判定，超过阈值就复位到自动选择组。
if [ -n "$POOL_GROUP" ] && [ -n "$POOL_FALLBACK_GROUP" ]; then
  P1=$($CURL -s -m 12 -o /dev/null -w "%{http_code} %{time_total}" -x "$PROXY" "$PROBE_URL" 2>/dev/null)
  P2=$($CURL -s -m 12 -o /dev/null -w "%{http_code} %{time_total}" -x "$PROXY" "$PROBE_URL" 2>/dev/null)
  if [ -n "$P1" ] && [ -n "$P2" ]; then
    # 两次探测取较慢那次（ARCHITECTURE §3.5）。$2/$4 是两次的耗时，
    # 取 max 后不能再除 2 —— 除 2 会把劣化阈值整体压低一半。
    MS=$(echo "$P1 $P2" | awk '{t=($2>$4?$2:$4)} END{printf "%.1f", t}')
    BAD=0
    case "${P1%% *}" in 2*|3*) ;; *) BAD=1 ;; esac
    case "${P2%% *}" in 2*|3*) ;; *) BAD=1 ;; esac
    if [ "$BAD" = "1" ] || ge_sec "$MS" "$EXIT_MAX_SEC"; then
      if [ "$(put "$POOL_GROUP" "$POOL_FALLBACK_GROUP")" = "204" ]; then
        log "FIX: 通用出口劣化（HTTP ${P1%% *}/${P2%% *}，耗时 ${MS}s，阈值 ${EXIT_MAX_SEC}s），复位为「$POOL_FALLBACK_GROUP」"
        ST_POOL="$POOL_FALLBACK_GROUP"
      else
        log "ERROR: 通用出口复位失败（控制 API 拒绝）"
      fi
    fi
  fi
fi

# ---------- 3.6) 干净出口健康守卫 ----------
# 干净出口会间歇性劣化。健康探测必须用真实页面 —— 小响应的 API 端点抓不到长尾。
# 候选顺序按实测稳定性排；绝不降级到「不可信」的节点（可能被目标站按地区拒绝服务）。
clean_exit_ms() {
  C1=$($CURL -s -m 15 -o /dev/null --max-filesize 131072 -w "%{http_code} %{time_total}" -x "$PROXY" "$CLEAN_PROBE_URL" 2>/dev/null)
  C2=$($CURL -s -m 15 -o /dev/null --max-filesize 131072 -w "%{http_code} %{time_total}" -x "$PROXY" "$CLEAN_PROBE_URL" 2>/dev/null)
  [ -z "$C1" ] && [ -z "$C2" ] && { echo "99"; return; }
  # 任一探测不是 2xx/3xx 都按劣化处理：节点被封/被拒时往往"快速失败"，
  # 只看 time_total 会把 502、连接被拒误判为健康。
  case "${C1%% *}" in 2*|3*) ;; *) echo "99"; return ;; esac
  case "${C2%% *}" in 2*|3*) ;; *) echo "99"; return ;; esac
  echo "$C1 $C2" | awk '{t=($2>$4?$2:$4)} END{printf "%.1f", t}'
}
clean_exit_bad() {
  MS=$(clean_exit_ms)
  ge_sec "$MS" "$CLEAN_EXIT_MAX_SEC"
}
if [ -n "$CLEAN_GROUP" ] && [ -n "$CL_CANDIDATES" ]; then
  CUR_CL=$(grp "$CLEAN_GROUP")
  [ -z "$ST_CLEAN" ] && ST_CLEAN="$CUR_CL"
  if [ -n "$CUR_CL" ] && clean_exit_bad; then
    if [ "$DRY_RUN" = "1" ]; then
      log "DRY-RUN: 干净出口劣化（当前入口「$CUR_CL」），本应按候选顺序轮换"
    else
      FIXED=""
      OLDIFS="$IFS"; IFS="|"
      for cand in $CL_CANDIDATES; do
        [ -z "$cand" ] && continue
        [ "$cand" = "$CUR_CL" ] && continue
        [ "$(put "$CLEAN_GROUP" "$cand")" = "204" ] || continue
        sleep 3
        if ! clean_exit_bad; then
          FIXED="$cand"; break
        fi
      done
      IFS="$OLDIFS"
      if [ -n "$FIXED" ]; then
        [ -n "$AI_FALLBACK_GROUP" ] && put "$AI_FALLBACK_GROUP" "$FIXED" >/dev/null 2>&1
        log "FIX: 干净出口劣化（当前入口「$CUR_CL」），已换到「$FIXED」；兜底组同步"
        ST_CLEAN="$FIXED"
      else
        [ "$CUR_CL" != "$(grp "$CLEAN_GROUP")" ] && put "$CLEAN_GROUP" "$CUR_CL" >/dev/null 2>&1
        log "ALERT: 干净出口候选全部劣化（已保持「$CUR_CL」）；不降级到不可信节点，目标站可能按地区拒绝服务"
      fi
    fi
  fi
fi

# ---------- 4) nft 表补载 ----------
for t in $NFT_TABLES; do
  [ -z "$t" ] && continue
  # "$t" 必须加引号：NFT_TABLES 来自 device.conf，含 * ? [ 时裸 $t 会被当成 glob
  # 展开成当前目录下的文件名，nft 收到的是完全无关的表名（P56）。
  if ! $NFT list table inet "$t" >/dev/null 2>&1; then
    if [ ! -f "$NFT_DIR/$t.nft" ]; then
      log "ERROR: nft 表 inet $t 缺失且 $NFT_DIR/$t.nft 不存在"
    elif [ "$DRY_RUN" = "1" ]; then
      log "DRY-RUN: nft 表 inet $t 缺失，本应从 $NFT_DIR/$t.nft 重载"
    elif $NFT -f "$NFT_DIR/$t.nft" >/dev/null 2>&1; then
      log "FIX: nft 表 inet $t 缺失，已从 $NFT_DIR/$t.nft 重载"
    else
      log "ERROR: nft 表 inet $t 缺失且重载失败"
    fi
  fi
done

# ---------- 5) 静默回退自愈 ----------
# 配置校验失败时 ShellCrash 只打一行日志就回退基础配置，自定义组与规则全丢。
if [ -n "$AI_FALLBACK_GROUP" ] && ! grep -Fq "name: $AI_FALLBACK_GROUP" "$RUNTIME_DIR/config.yaml" 2>/dev/null; then
  LASTF="$RUNTIME_DIR/.last_fallback_heal"
  NOWT=$(date +%s)
  PREV=$(cat "$LASTF" 2>/dev/null || echo 0)
  if [ $((NOWT - PREV)) -gt "$FALLBACK_HEAL_INTERVAL" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      log "DRY-RUN: 运行配置缺 $AI_FALLBACK_GROUP 组，本应重跑 hotupdate"
    else
      echo $NOWT > "$LASTF"
      log "FIX: 运行配置缺 $AI_FALLBACK_GROUP 组（疑为回退基础配置），重跑 hotupdate 重新生成"
      /bin/ash "$TASK_SH" hotupdate >> "$LOG" 2>&1
    fi
  else
    log "WARN: 运行配置缺 $AI_FALLBACK_GROUP 组（疑为回退基础配置），限频窗口内不重复重生成"
  fi
fi

# ---------- 6) 探活与内存水位（内存不足是 OOM 根因，必须盯） ----------
# 地区判定探测：cc 变量在页面 1MB 之后，不要每次都拉。
CCF="$RUNTIME_DIR/.cc_probe_ts"
NOWT2=$(date +%s)
LASTF2=$(cat "$CCF" 2>/dev/null || echo 0)
if [ $((NOWT2 - LASTF2)) -ge 3600 ]; then
  echo $NOWT2 > "$CCF"
  CC=$($CURL -s -m 20 -x "$PROXY" "$CC_PROBE_URL" 2>/dev/null | grep -oE "var cc=.[A-Z]{2}" | head -1 | sed "s/var cc=.//")
  if [ -n "$CC" ]; then
    log "INFO: 出口地区判定 cc=$CC"
    if [ -n "$CC_EXPECT" ] && [ "$CC" != "$CC_EXPECT" ]; then
      log "ALERT: 出口地区判定 cc=$CC（期望 $CC_EXPECT），目标站可能按地区拒绝服务，需更换节点"
    fi
  else
    log "WARN: 地区判定探测未取到结果（页面未下完或节点超时）"
  fi
fi
AVAIL=$(awk '/^MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
# 有 zram 压缩 swap 时，MemAvailable 之外还有一层缓冲：匿名页先被压进 RAM，而不是被
# OOM killer 直接抬走。但 zram 的 disksize 是**逻辑容量**，压缩比通常 2–3x —— 折半计入，
# 免得把 116MB 的逻辑 swap 当成 116MB 白送的物理内存（2026-11-13 起设备默认带 zram）。
SWAPFREE=$(awk '/^SwapFree/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
EFFECTIVE="${AVAIL:-}"
case "${SWAPFREE:-0}" in
  ''|0|*[!0-9]*) ;;
  *) [ -n "$AVAIL" ] && EFFECTIVE=$((AVAIL + SWAPFREE / 2)) ;;
esac
if [ -n "$EFFECTIVE" ] && [ "$EFFECTIVE" -lt "$MEM_LOW_MB" ]; then
  if [ -n "$SWAPFREE" ] && [ "$SWAPFREE" -gt 0 ]; then
    log "WARN: 可用内存仅 ${AVAIL}MB（zram 余量 ${SWAPFREE}MB 折半后折算 ${EFFECTIVE}MB，低于 ${MEM_LOW_MB}MB 阈值，注意 OOM 风险）"
  else
    log "WARN: 可用内存仅 ${AVAIL}MB（无 swap 兜底，低于 ${MEM_LOW_MB}MB 阈值，注意 OOM 风险）"
  fi
fi

# /tmp 是内存盘，一旦被写满会连锁 OOM。超阈值就清掉已知的临时大文件。
# 一次 df 取「已用/总量」两个字段：原来连跑两次 df（各 2 个 fork），
# 且两次读数之间 /tmp 还在涨，算出来的百分比本身就不自洽。
TMPDF=$(df -k /tmp 2>/dev/null | awk 'END{print $3" "$2}')
TMPK=${TMPDF%% *}
TMPT=${TMPDF##* }
if [ -n "$TMPK" ] && [ -n "$TMPT" ] && [ "$TMPT" -gt 0 ]; then
  TMPP=$((TMPK * 100 / TMPT))
  if [ "$TMPP" -ge "$TMPFS_WARN_PCT" ]; then
    log "WARN: /tmp 内存盘已用 ${TMPP}%（${TMPK}K/${TMPT}K），接近撑爆会 OOM 并触发看门狗重启"
    for f in $TMPFS_CLEAN_FILES; do
      [ -z "$f" ] && continue
      [ -e "$f" ] || continue
      # 白名单式清理（P28）。前缀判断不够：/tmp/../etc/passwd 也能通过 /tmp/*，
      # 而 "/tmp/" 自身会命中 /tmp/*（* 可匹配空串），rm -rf 就是清空整个 tmpfs。
      # 所以先拦 .. 与 /tmp 本身，再要求 /tmp/ 后至少还有一个字符。
      case "$f" in
        *..*) log "SKIP: TMPFS_CLEAN_FILES 路径含 ..（$f），拒绝清理"; continue ;;
        /tmp|/tmp/) log "SKIP: TMPFS_CLEAN_FILES 不允许指向 /tmp 本身"; continue ;;
        /tmp/?*) ;;
        *) log "SKIP: TMPFS_CLEAN_FILES 含 /tmp 之外的路径 $f，拒绝清理"; continue ;;
      esac
      if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: 本应清理 /tmp 临时大文件 $f"
      else
        rm -rf "$f" 2>/dev/null
        log "FIX: 已清理 /tmp 临时大文件 $f"
      fi
    done
    TMPK2=$(df -k /tmp 2>/dev/null | awk 'END{print $3}')
    log "INFO: /tmp 清理后占用 ${TMPK2:-?}K/${TMPT}K"
  fi
fi

# cron lifeline: start.sh stop 会重写 crontab 并删掉 legacy 看门狗行,这里补回去
if [ -n "$LEGACY_WD" ] && [ -f "$LEGACY_WD" ]; then
  # -F：路径里的 . * [ 等字符按字面匹配，否则一个带点的路径会误判「已存在」而漏补（P33）
  _wd_base=${LEGACY_WD##*/}
  if ! grep -Fq "$_wd_base" "$CRON_FILE" 2>/dev/null; then
    if [ "$DRY_RUN" = "1" ]; then
      log "DRY-RUN: 本应补回 legacy 看门狗 cron 行"
    else
      echo "* * * * * /bin/ash $LEGACY_WD shellcrash #ShellCrash保守模式守护进程" >> "$CRON_FILE"
      crontab "$CRON_FILE" 2>/dev/null
      log "FIX: restored legacy watchdog cron line"
    fi
  fi
fi

# ---------- 收尾：机器可读状态（tmpfs，不占闪存写入）----------
# 多行 key=value（值可含空格，按第一个 = 切分）：ops-status.sh 与 AX3000TOpenwrt 的
# health-snapshot.sh --json 都按这个格式读，键名与 AX3000TOpenwrt 的 guardian.state 对齐。
# 原子写（.tmp.$$ + mv）：读者不会读到写了一半的文件（P54）。
# --status 在上面就退出了，不会覆盖真实状态；dry-run 也写，靠 mode 区分。
ST_TMP="$GUARDIAN_STATE.tmp.$$"
{
  printf 'ts=%s\n' "$(date +%s)"
  printf 'schema=openwrt-ops-guardian/1\n'
  printf 'mode=%s\n' "$MODE"
  printf 'dry_run=%s\n' "$DRY_RUN"
  printf 'fixes=%s\n' "$FIXES"
  printf 'errors=%s\n' "$ERRORS"
  printf 'alerts=%s\n' "$ALERTS"
  printf 'warns=%s\n' "$WARNS"
  printf 'wouldfix=%s\n' "$WOULDFIX"
  printf 'mem_avail_mb=%s\n' "${AVAIL:-}"
  printf 'mem_eff_mb=%s\n' "${EFFECTIVE:-}"
  printf 'tmp_pct=%s\n' "${TMPP:-}"
  printf 'pool=%s\n' "$ST_POOL"
  printf 'ai_exit=%s\n' "$ST_AI"
  printf 'clean_node=%s\n' "$ST_CLEAN"
} > "$ST_TMP" 2>/dev/null && mv -f "$ST_TMP" "$GUARDIAN_STATE" 2>/dev/null || rm -f "$ST_TMP" 2>/dev/null

exit 0
