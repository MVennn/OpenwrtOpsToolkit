#!/bin/sh
# ============================================================================
# 只读健康快照 / 自检 —— 给控制台与运维工具消费的稳定接口
#
# 定位：本仓各脚本（guardian / bulk-guard / traffic-stats / post-sc-update）
# 各自只写自己的状态文件与日志，**没有**统一的对外查询面。这个脚本只做三件事：
#   1. 按各脚本自己的默认值/配置解析出它们真正在用的路径（不猜、不复制逻辑）
#   2. 把这些状态读出来，拼成一份 schema 固定的 JSON（openwrt-ops-status/1）
#   3. --self-check 做一次人读的自检（配置解析、依赖、权限、日志水位）
#
# 硬约束：
#   * 只读。绝不写设备状态、绝不动 nft/crontab/进程；不取实例锁（不能干扰守护）
#   * 不用 jq/python，只用 busybox 自带的 awk/sed/grep/printf
#   * 不输出任何凭据：secret 只报「有/无」，绝不打印内容
#
# 用法：
#   sh ops-status.sh                # JSON（默认，schema=openwrt-ops-status/1）
#   sh ops-status.sh --json         # 同上
#   sh ops-status.sh --self-check   # 人读自检，结论行只用 ASCII（P44 GBK 控制台）
#   DEVICE_CONF=/etc/openwrt-ops/device.conf sh ops-status.sh
#
# 跨仓联动：AX3000TOpenwrt 侧产出三个机器可读状态口，本脚本只读并并进 JSON 的
# cross_repo 段（两个 .state 是 KV，health.json 原样内嵌）：
#   $RUNTIME_DIR/guardian.state      守护每轮动作计数与出口快照
#   $RUNTIME_DIR/dest-guard.state    目标站守卫的逐项结果
#   /tmp/router-health/health.json   路由侧结构化健康快照（tmpfs）
# 三个文件都不在也照常出快照（对应字段 null / present=false），绝不假设它们存在。
#
# 退出码：0 正常；1 自检发现问题；2 参数错误
# ============================================================================

# ---------------------------------------------------------------------------
# 配置加载：环境变量 > device.conf > 本文件里的默认值（与 guardian.sh 同一套）
# ---------------------------------------------------------------------------
OPS_CONF=${DEVICE_CONF:-}
if [ -z "$OPS_CONF" ]; then
  OPS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
  [ -n "$OPS_DIR" ] || OPS_DIR="."
  for _c in "$OPS_DIR/conf/device.conf" /etc/openwrt-ops/device.conf; do
    if [ -f "$_c" ]; then OPS_CONF="$_c"; break; fi
  done
fi

_OPS_VARS="CRASHDIR RUNTIME_DIR API_CFG GUARDIAN_LOG BULK_LOG BULK_STATE BULK_SPEED_STATE BULK_TRIED BULK_LOCK GUARDIAN_LOCK ALIVEF ROUTER_HEALTH_DIR TMPFS_WARN_PCT MEM_LOW_MB GUARDIAN_STATE DEST_GUARD_STATE HEALTH_JSON CROSS_STATE_STALE_SEC"
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
# 默认值：必须与各脚本里的默认值逐字一致，否则快照报的路径不是它们真正在用的
# ---------------------------------------------------------------------------
CRASHDIR=${CRASHDIR:-/etc/ShellCrash}
RUNTIME_DIR=${RUNTIME_DIR:-/tmp/ShellCrash}
API_CFG=${API_CFG:-$CRASHDIR/configs/ShellCrash.cfg}
GUARDIAN_LOG=${GUARDIAN_LOG:-$RUNTIME_DIR/guardian.log}
BULK_LOG=${BULK_LOG:-$RUNTIME_DIR/bulk-guard.log}
BULK_STATE=${BULK_STATE:-$RUNTIME_DIR/.bulk_guard_state}
BULK_SPEED_STATE=${BULK_SPEED_STATE:-$RUNTIME_DIR/.bulk_guard_speed}
BULK_TRIED=${BULK_TRIED:-$RUNTIME_DIR/.bulk_guard_tried}
BULK_LOCK=${BULK_LOCK:-$RUNTIME_DIR/.bulk_guard.lock}
GUARDIAN_LOCK=${GUARDIAN_LOCK:-$RUNTIME_DIR/guardian.lock}
ALIVEF=${ALIVEF:-$RUNTIME_DIR/.proxy_alive}
STATS_DIR="$CRASHDIR/stats"
STATS_FLUSH_MIN=${STATS_FLUSH_MIN:-10}
ROUTER_HEALTH_DIR=${ROUTER_HEALTH_DIR:-/etc/router-health}
# 跨仓机器可读状态口（AX3000TOpenwrt 侧产出）。health.json 与 health-*.log 不在同一个
# 目录不是笔误：日志进闪存目录留时间线，结构化快照写 tmpfs，不占闪存写入预算。
# 守护状态有两个候选：本仓 ops 版写 ops-guardian.state，AX3000TOpenwrt 版写
# guardian.state。按顺序探测，先存在的胜出 —— 两版同装时不互相覆盖（P57）。
GUARDIAN_STATE=${GUARDIAN_STATE:-}
if [ -z "$GUARDIAN_STATE" ]; then
  if [ -f "$RUNTIME_DIR/ops-guardian.state" ]; then
    GUARDIAN_STATE="$RUNTIME_DIR/ops-guardian.state"
  else
    GUARDIAN_STATE="$RUNTIME_DIR/guardian.state"
  fi
fi
DEST_GUARD_STATE=${DEST_GUARD_STATE:-$RUNTIME_DIR/dest-guard.state}
HEALTH_JSON=${HEALTH_JSON:-/tmp/router-health/health.json}
# 状态口多久没更新算「陈旧」：守护 cron 是 */5，默认 1800s = 连丢 6 轮。
CROSS_STATE_STALE_SEC=${CROSS_STATE_STALE_SEC:-1800}
# 水位阈值必须与 guardian.sh 同源：同名的键不能在两个脚本里有两种含义（P55）。
# 守护在 80% / 30MB 就动手，快照却按 85% / 40MB 报，会出现「自检 [ok] 但守护已在告警」。
TMPFS_WARN_PCT=${TMPFS_WARN_PCT:-80}
MEM_LOW_MB=${MEM_LOW_MB:-30}
SCHEMA=openwrt-ops-status/1

MODE=json
case "${1:-}" in
  --json|"") MODE=json ;;
  --self-check|--check) MODE=selfcheck ;;
  -h|--help) awk 'NR>1{ if(/^# =====/){ if(++n==2) exit; if(n==1) next } print }' "$0"; exit 0 ;;
  *) echo "未知参数：${1:-}（可用：--json / --self-check）" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# 小工具（都不起多余子进程：printf/read 是 ash 内建）
# ---------------------------------------------------------------------------
jstr() { printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r/ /g' -e 's/\t/ /g'; }
jnum() {
  case "${1:-}" in
    ''|*[!0-9]*) printf 'null' ;;
    *) printf '%s' "${1:-}" ;;
  esac
}
jbool() { [ "${1:-0}" = "1" ] && printf 'true' || printf 'false'; }
# 内存类字段：测不到就出 null，绝不把「没读到」写成 0
memj() { if [ "$MEM_OK" = "1" ]; then jnum "$1"; else printf 'null'; fi }

# 文件字节数：wc 的输出可能带前导空格，用 \${x##* } 剥掉，不再多起一个 tr
fsize() {
  [ -f "${1:-}" ] || { printf '0'; return 0; }
  _fs=$(wc -c < "$1" 2>/dev/null)
  case "${_fs##* }" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "${_fs##* }" ;;
  esac
}
# 最后一行（日志尾巴），去掉可能存在的 \r
lastline() {
  [ -f "${1:-}" ] || return 0
  tail -n 1 "${1:-}" 2>/dev/null | sed -e 's/\r$//'
}
# 最后一条 FIX/ALERT/ERROR/WARN 行（syslog 只收这几类，P30）
lastalert() {
  [ -f "${1:-}" ] || return 0
  grep -E 'FIX|ALERT|ERROR|WARN' "${1:-}" 2>/dev/null | tail -n 1 | sed -e 's/\r$//'
}
# 实例锁：输出 "held pid age_s"（不在锁里输出 "0 0 0"）
lock_info() {
  _ld="${1:-}"
  if [ -d "$_ld" ]; then
    _lp=$(cat "$_ld/pid" 2>/dev/null)
    _lt=$(cat "$_ld/ts" 2>/dev/null)
    case "${_lt:-}" in ''|*[!0-9]*) _lt=0 ;; esac
    case "${_lp:-}" in ''|*[!0-9]*) _lp=0 ;; esac
    _age=0
    [ "$_lt" -gt 0 ] 2>/dev/null && _age=$((NOW_TS - _lt))
    [ "$_age" -lt 0 ] 2>/dev/null && _age=0
    printf '1 %s %s' "${_lp:-0}" "$_age"
  else
    printf '0 0 0'
  fi
}
# 时间戳距今秒数（读不到就 null）
age_of_file_ts() {
  _t=$(cat "${1:-}" 2>/dev/null)
  case "${_t:-}" in ''|*[!0-9]*) printf 'null'; return 0 ;; esac
  _a=$((NOW_TS - _t))
  [ "$_a" -lt 0 ] 2>/dev/null && _a=0
  printf '%s' "$_a"
}
# epoch 距今秒数（读不到 / 不是数字 → null，绝不写 0）
age_of_epoch() {
  case "${1:-}" in ''|*[!0-9]*) printf 'null'; return 0 ;; esac
  _a=$((NOW_TS - $1))
  [ "$_a" -lt 0 ] 2>/dev/null && _a=0
  printf '%s' "$_a"
}
# 多行 KV 状态文件 → JSON 对象（值可含空格，按第一个 = 切；键为空的行跳过）。
# 文件不在就出 null：消费方必须能区分「没有这个口」和「口里全是空值」。
kv_json() {
  [ -f "${1:-}" ] || { printf 'null'; return 0; }
  _o=""
  while IFS='=' read -r _k _v; do
    [ -n "$_k" ] || continue
    _o="$_o$(printf '"%s": "%s", ' "$(jstr "$_k")" "$(jstr "$_v")")"
  done < "$1"
  printf '{%s}' "${_o%, }"
}
# KV 文件里的 ts=（epoch），交给 age_of_epoch
kv_ts() { [ -f "${1:-}" ] || return 0; sed -n 's/^ts=//p' "$1" 2>/dev/null | head -1; }
# health.json 里的 "epoch": N
json_epoch() { [ -f "${1:-}" ] || return 0; sed -n 's/.*"epoch": *\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -1; }
# 已经是 JSON 的文件原样内嵌（写方 tmp+mv 原子落盘，读不到半截）；
# 首尾不是 {} 就出 null —— 宁缺勿造，别把半截 JSON 拼进我们的快照。
json_blob() {
  [ -f "${1:-}" ] || { printf 'null'; return 0; }
  _c=$(tr -d '\r\n' < "$1" 2>/dev/null)
  case "$_c" in
    \{*\}) printf '%s' "$_c" ;;
    *) printf 'null' ;;
  esac
}

NOW_TS=$(date +%s)
NOW_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
HOST=$(cat /proc/sys/kernel/hostname 2>/dev/null || uname -n 2>/dev/null)

# 内存：一次 awk 取全部字段（原来每个指标一个 grep，4 个 fork）
_mem=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
            END{printf "%d %d %d %d", t/1024, a/1024, st/1024, sf/1024}' /proc/meminfo 2>/dev/null)
MEM_TOTAL=${_mem%% *}; _r=${_mem#* }
MEM_AVAIL=${_r%% *}; _r=${_r#* }
SWAP_TOTAL=${_r%% *}
SWAP_FREE=${_r##* }
for _v in MEM_TOTAL MEM_AVAIL SWAP_TOTAL SWAP_FREE; do
  eval "_x=\$_${_v}"
  case "${_x:-}" in ''|*[!0-9]*) eval "${_v}=0" ;; esac
done
# 宽松内存 = MemAvailable + SwapFree/2（zram 逻辑容量折半，P47）
MEM_EFFECTIVE=$((MEM_AVAIL + SWAP_FREE / 2))
# 读不到 /proc/meminfo（非 Linux / 权限异常）时不能报「0MB = 内存耗尽」，
# 那会把「测不到」误报成「快 OOM」，运维按它去清缓存反而添乱。
MEM_OK=1
[ "$MEM_TOTAL" -gt 0 ] || MEM_OK=0

# /tmp 水位：一次 df
_tmp=$(df -k /tmp 2>/dev/null | awk 'END{print $3" "$2}')
TMP_USED=${_tmp%% *}
TMP_TOTAL=${_tmp##* }
case "${TMP_USED:-}" in ''|*[!0-9]*) TMP_USED=0 ;; esac
case "${TMP_TOTAL:-}" in ''|*[!0-9]*) TMP_TOTAL=0 ;; esac
TMP_PCT=0
[ "$TMP_TOTAL" -gt 0 ] && TMP_PCT=$((TMP_USED * 100 / TMP_TOTAL))

read -r LOAD1 LOAD5 LOAD15 _REST < /proc/loadavg 2>/dev/null || { LOAD1=""; LOAD5=""; LOAD15=""; }
UPTIME_S=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)

# 跨仓状态口：存在性 + 新鲜度。读不到一律 present=false / age=null，
# 绝不当成「全 0 = 一切正常」（P54：没有年龄判定的状态口会把三小时前的快照当现状）。
GSTATE_PRESENT=0; GSTATE_AGE=null
if [ -f "$GUARDIAN_STATE" ]; then
  GSTATE_PRESENT=1
  GSTATE_AGE=$(age_of_epoch "$(kv_ts "$GUARDIAN_STATE")")
fi
DSTATE_PRESENT=0; DSTATE_AGE=null
if [ -f "$DEST_GUARD_STATE" ]; then
  DSTATE_PRESENT=1
  DSTATE_AGE=$(age_of_epoch "$(kv_ts "$DEST_GUARD_STATE")")
fi
HJ_PRESENT=0; HJ_AGE=null
if [ -f "$HEALTH_JSON" ]; then
  HJ_PRESENT=1
  HJ_AGE=$(age_of_epoch "$(json_epoch "$HEALTH_JSON")")
fi

# ---------------------------------------------------------------------------
# --self-check：人读自检。结论行只用 [ok]/[warn]/[fail] + ASCII 标记（P44）
# ---------------------------------------------------------------------------
if [ "$MODE" = "selfcheck" ]; then
  FAILN=0
  WARNN=0
  ok()   { echo "[ok]   $*"; }
  warn() { echo "[warn] $*"; WARNN=$((WARNN + 1)); }
  bad()  { echo "[fail] $*"; FAILN=$((FAILN + 1)); }

  echo "== 配置 =="
  if [ -n "$OPS_CONF" ] && [ -f "$OPS_CONF" ]; then
    ok "device.conf: $OPS_CONF"
  else
    warn "没有 device.conf（DEVICE_CONF / ./conf/device.conf / /etc/openwrt-ops/device.conf 都没有），全部走占位符默认值"
  fi
  for _d in "$CRASHDIR" "$RUNTIME_DIR"; do
    if [ -d "$_d" ]; then ok "目录存在: $_d"; else bad "目录缺失: $_d"; fi
  done
  if [ -w "$RUNTIME_DIR" ] 2>/dev/null; then ok "运行时目录可写: $RUNTIME_DIR"; else warn "运行时目录不可写: $RUNTIME_DIR"; fi

  echo "== 凭据 =="
  if [ -r "$API_CFG" ]; then
    # >>> shared:secret-read >>>
    API_SECRET=$(sed -n 's/^secret=//p' "$API_CFG" 2>/dev/null | head -1 | tr -d '\r')
    # <<< shared:secret-read <<<
    _s="$API_SECRET"
    if [ -n "$_s" ]; then ok "控制 API secret: set（不打印内容）"; else warn "控制 API secret: unset（核心未开鉴权，或配置文件里没有 secret= 行）"; fi
    unset _s
  else
    bad "读不到 API 配置: $API_CFG"
  fi

  echo "== 依赖 =="
  for _t in curl awk sed grep tail df date netstat nft logger; do
    if command -v "$_t" >/dev/null 2>&1; then ok "命令可用: $_t"; else warn "命令缺失: $_t"; fi
  done

  echo "== 脚本语法 =="
  _sd=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
  for _f in guardian.sh bulk-guard.sh traffic-stats.sh post-sc-update.sh setup-zram.sh recover-now.sh rc.local; do
    if [ ! -f "$_sd/$_f" ]; then warn "脚本缺失: $_f"; continue; fi
    if sh -n "$_sd/$_f" 2>/dev/null; then ok "语法通过: $_f"; else bad "语法错误: $_f"; fi
  done

  echo "== 水位 =="
  if [ "$TMP_TOTAL" -le 0 ]; then
    warn "/tmp 用量读不到（df 失败或没有 /tmp 挂载），本轮不判断水位"
  elif [ "$TMP_PCT" -ge "$TMPFS_WARN_PCT" ]; then
    bad "/tmp 已用 ${TMP_PCT}%（阈值 ${TMPFS_WARN_PCT}%，tmpfs 写满会连锁 OOM）"
  else
    ok "/tmp 已用 ${TMP_PCT}%（${TMP_USED}K/${TMP_TOTAL}K，阈值 ${TMPFS_WARN_PCT}%）"
  fi
  if [ "$MEM_OK" != "1" ]; then
    warn "读不到 /proc/meminfo，跳过内存水位判断"
  elif [ "$MEM_EFFECTIVE" -lt "$MEM_LOW_MB" ]; then
    bad "宽松内存仅 ${MEM_EFFECTIVE}MB（阈值 ${MEM_LOW_MB}MB）"
  else
    ok "宽松内存 ${MEM_EFFECTIVE}MB（MemAvailable ${MEM_AVAIL}MB + SwapFree/2 ${SWAP_FREE}MB 折半，阈值 ${MEM_LOW_MB}MB）"
  fi
  for _l in "$GUARDIAN_LOG" "$BULK_LOG"; do
    _sz=$(fsize "$_l")
    if [ "$_sz" -gt 204800 ]; then
      warn "日志超过 200KB 未被截尾: $_l (${_sz}B)"
    else
      ok "日志水位: $_l (${_sz}B)"
    fi
  done
  if [ -f "$GUARDIAN_LOG" ] && [ -f "$BULK_LOG" ]; then :; else warn "有守护日志还没生成过（守护没跑过或 RUNTIME_DIR 刚重建）"; fi

  echo "== 跨仓状态口 =="
  # 用函数而不是「冒号拼串再切」：路径本身可能含冒号（DEVICE_CONF 指到别处时），
  # 切串会把 /tmp/... 切成一段残串，报出来的路径是错的。
  cross_check() {  # $1=名字 $2=路径 $3=present $4=age
    if [ "$3" != "1" ]; then
      warn "状态口缺失: $1（$2）—— 生产方没跑过，或路径配错"
      return 0
    fi
    case "$4" in
      null) ok "状态口 $1: 有文件但没有 ts 键（$2）" ;;
      *)
        if [ "$4" -gt "$CROSS_STATE_STALE_SEC" ]; then
          warn "状态口陈旧: $1 已 ${4}s 未更新（阈值 ${CROSS_STATE_STALE_SEC}s，$2）"
        else
          ok "状态口 $1: ${4}s 前更新（$2）"
        fi
        ;;
    esac
  }
  cross_check guardian.state "$GUARDIAN_STATE" "$GSTATE_PRESENT" "$GSTATE_AGE"
  cross_check dest-guard.state "$DEST_GUARD_STATE" "$DSTATE_PRESENT" "$DSTATE_AGE"
  cross_check health.json "$HEALTH_JSON" "$HJ_PRESENT" "$HJ_AGE"

  echo "== 结论 =="
  echo "fail=${FAILN} warn=${WARNN}"
  [ "$FAILN" -eq 0 ] || exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# JSON 快照
# ---------------------------------------------------------------------------
set -- $(lock_info "$GUARDIAN_LOCK")
G_LOCK_HELD=$1; G_LOCK_PID=$2; G_LOCK_AGE=$3
set -- $(lock_info "$BULK_LOCK")
B_LOCK_HELD=$1; B_LOCK_PID=$2; B_LOCK_AGE=$3

# 一次读完整个状态文件：原来每个键一次 sed|head，4 个键 = 8 个 fork。
B_LAST_PROBE=""; B_COOLDOWN=""; B_LAST_MOVING=""; B_FAILS=""
if [ -f "$BULK_STATE" ]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in
      last_probe) B_LAST_PROBE=$_v ;;
      cooldown_until) B_COOLDOWN=$_v ;;
      last_moving) B_LAST_MOVING=$_v ;;
      fails) B_FAILS=$_v ;;
    esac
  done < "$BULK_STATE"
fi
B_SPEED_N=0
[ -f "$BULK_SPEED_STATE" ] && B_SPEED_N=$(grep -c . "$BULK_SPEED_STATE" 2>/dev/null)
B_TRIED_N=0
[ -f "$BULK_TRIED" ] && B_TRIED_N=$(grep -c . "$BULK_TRIED" 2>/dev/null)

T_DAYS=0
T_LATEST=""
for _f in "$STATS_DIR"/*.tsv; do
  [ -f "$_f" ] || continue
  T_DAYS=$((T_DAYS + 1))
  _b=${_f##*/}
  T_LATEST=${_b%.tsv}
done
T_BUF_BYTES=0
for _b in "$RUNTIME_DIR"/traffic-stats.buf.*; do
  [ -f "$_b" ] || continue
  T_BUF_BYTES=$((T_BUF_BYTES + $(fsize "$_b")))
done

# 路由侧健康快照：AX3000TOpenwrt 的 health-snapshot.sh 往这里追加单行 key=value，
# 本脚本只做「读最后一行 + 拆 k=v」，格式不认识就整段省略，绝不假设字段一定存在。
H_LOG=""
for _f in "$ROUTER_HEALTH_DIR"/health-*.log; do
  [ -f "$_f" ] && H_LOG=$_f
done
H_LINE=""
[ -n "$H_LOG" ] && H_LINE=$(lastline "$H_LOG")
H_TS=""
case "$H_LINE" in
  *ts=*)
    for _kv in $H_LINE; do
      case "$_kv" in ts=*) H_TS=${_kv#ts=} ;; esac
    done
    ;;
esac
H_AGE="null"
case "${H_TS:-}" in
  ''|*[!0-9]*) ;;
  *) H_AGE=$((NOW_TS - H_TS)); [ "$H_AGE" -lt 0 ] && H_AGE=0 ;;
esac

printf '{\n'
printf '  "schema": "%s",\n' "$SCHEMA"
printf '  "ts": %s,\n' "$NOW_TS"
printf '  "ts_human": "%s",\n' "$NOW_HUMAN"
printf '  "host": "%s",\n' "$(jstr "$HOST")"
printf '  "readonly": true,\n'
printf '  "load": {"l1": %s, "l5": %s, "l15": %s},\n' "$(jnum "$LOAD1")" "$(jnum "$LOAD5")" "$(jnum "$LOAD15")"
printf '  "uptime_s": %s,\n' "$(jnum "$UPTIME_S")"
printf '  "mem": {"total_mb": %s, "avail_mb": %s, "swap_total_mb": %s, "swap_free_mb": %s, "effective_mb": %s},\n' \
  "$(memj "$MEM_TOTAL")" "$(memj "$MEM_AVAIL")" "$(memj "$SWAP_TOTAL")" "$(memj "$SWAP_FREE")" "$(memj "$MEM_EFFECTIVE")"
printf '  "tmpfs": {"path": "/tmp", "used_kb": %s, "total_kb": %s, "pct": %s, "warn_pct": %s},\n' \
  "$(jnum "$TMP_USED")" "$(jnum "$TMP_TOTAL")" "$(jnum "$TMP_PCT")" "$(jnum "$TMPFS_WARN_PCT")"
printf '  "guardian": {"log": "%s", "log_bytes": %s, "lock": {"held": %s, "pid": %s, "age_s": %s}, "alive_age_s": %s, "last_event": "%s", "last_alert": "%s"},\n' \
  "$(jstr "$GUARDIAN_LOG")" "$(fsize "$GUARDIAN_LOG")" "$(jbool "$G_LOCK_HELD")" "$(jnum "$G_LOCK_PID")" "$(jnum "$G_LOCK_AGE")" \
  "$(age_of_file_ts "$ALIVEF")" "$(jstr "$(lastline "$GUARDIAN_LOG")")" "$(jstr "$(lastalert "$GUARDIAN_LOG")")"
printf '  "bulk_guard": {"log": "%s", "log_bytes": %s, "lock": {"held": %s, "pid": %s, "age_s": %s}, "state": {"last_probe": %s, "cooldown_until": %s, "last_moving": %s, "fails": %s}, "speed_entries": %s, "tried_nodes": %s},\n' \
  "$(jstr "$BULK_LOG")" "$(fsize "$BULK_LOG")" "$(jbool "$B_LOCK_HELD")" "$(jnum "$B_LOCK_PID")" "$(jnum "$B_LOCK_AGE")" \
  "$(jnum "$B_LAST_PROBE")" "$(jnum "$B_COOLDOWN")" "$(jnum "$B_LAST_MOVING")" "$(jnum "$B_FAILS")" \
  "$(jnum "$B_SPEED_N")" "$(jnum "$B_TRIED_N")"
printf '  "traffic": {"stats_dir": "%s", "days": %s, "latest_day": "%s", "buffer_bytes": %s, "flush_min": %s},\n' \
  "$(jstr "$STATS_DIR")" "$(jnum "$T_DAYS")" "$(jstr "$T_LATEST")" "$(jnum "$T_BUF_BYTES")" "$(jnum "$STATS_FLUSH_MIN")"
printf '  "router_health": {"dir": "%s", "log": "%s", "age_s": %s, "last_line": "%s"},\n' \
  "$(jstr "$ROUTER_HEALTH_DIR")" "$(jstr "$H_LOG")" "$H_AGE" "$(jstr "$H_LINE")"
# 跨仓三状态口：两个 KV 原样转成子对象，health.json 本身就是 JSON 直接内嵌。
# 只增字段（schema 仍是 openwrt-ops-status/1），消费方必须容忍未知键与 null。
printf '  "cross_repo": {"stale_after_s": %s,\n' "$(jnum "$CROSS_STATE_STALE_SEC")"
printf '    "guardian_state": {"path": "%s", "present": %s, "age_s": %s, "fields": %s},\n' \
  "$(jstr "$GUARDIAN_STATE")" "$(jbool "$GSTATE_PRESENT")" "$GSTATE_AGE" "$(kv_json "$GUARDIAN_STATE")"
printf '    "dest_guard_state": {"path": "%s", "present": %s, "age_s": %s, "fields": %s},\n' \
  "$(jstr "$DEST_GUARD_STATE")" "$(jbool "$DSTATE_PRESENT")" "$DSTATE_AGE" "$(kv_json "$DEST_GUARD_STATE")"
printf '    "health_json": {"path": "%s", "present": %s, "age_s": %s, "doc": %s}}\n' \
  "$(jstr "$HEALTH_JSON")" "$(jbool "$HJ_PRESENT")" "$HJ_AGE" "$(json_blob "$HEALTH_JSON")"
printf '}\n'
exit 0
