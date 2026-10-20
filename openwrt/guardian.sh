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
#   DEVICE_CONF=/etc/openwrt-ops/device.conf sh guardian.sh
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
_OPS_VARS="CRASHDIR RUNTIME_DIR CTRL_HOST CTRL_PORT PROXY_PORT MIXED_PORT DNS_PORT CORE_PROC NFT_DIR NFT_TABLES CRON_FILE GUARDIAN_LOG START_SH TASK_SH LEGACY_WD API_CFG AI_GROUP AI_FALLBACK_GROUP CLEAN_GROUP CLEAN_NODE CL_CANDIDATES POOL_GROUP POOL_FALLBACK_GROUP MANUAL_GROUP AI_BAD_NODES POOL_BLOCKED_NODES PROBE_URL CLEAN_PROBE_URL CC_PROBE_URL CC_EXPECT EXIT_MAX_SEC CLEAN_EXIT_MAX_SEC MEM_LOW_MB TMPFS_WARN_PCT FALLBACK_HEAL_INTERVAL ALIVE_STALE_SEC TMPFS_CLEAN_FILES ROUTER_HEALTH_DIR"
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
# 干跑模式：只检测、只报告，不改设备任何状态
DRY_RUN="${DRY_RUN:-0}"
case "${1:-}" in
  --dry-run|-n) DRY_RUN=1 ;;
esac

mkdir -p "$RUNTIME_DIR" 2>/dev/null
LOG="$GUARDIAN_LOG"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
CURL="${CURL:-/usr/bin/curl}"
[ -x "$CURL" ] || CURL=curl
NFT="${NFT:-/usr/sbin/nft}"
[ -x "$NFT" ] || NFT=nft
CTRL="http://$CTRL_HOST:$CTRL_PORT"
PROXY="http://127.0.0.1:$PROXY_PORT"
PIDFILE="$RUNTIME_DIR/shellcrash.pid"
ALIVEF="$RUNTIME_DIR/.proxy_alive"

# API secret 从设备上的配置现读，不写死在脚本里
API_SECRET=$(sed -n "s/^secret=//p" "$API_CFG" 2>/dev/null | head -1)
SECRET="$API_SECRET"
AUTH="Authorization: Bearer $SECRET"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() {
  echo "$(ts) $*" >> "$LOG"
  case "$*" in
    *FIX*|*ALERT*|*ERROR*|*WARN*) logger -t guardian -p daemon.warn "$*" 2>/dev/null ;;
  esac
}
enc() { echo "$1" | sed 's/ /%20/g'; }
grp() { $CURL -s -m 5 -H "$AUTH" "$CTRL/proxies/$(enc "$1")" 2>/dev/null | grep -oE '"now":"[^"]*"' | head -1 | sed 's/"now":"//;s/"$//'; }
put() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN: 将把「$1」切到「$2」"
    echo 204
    return 0
  fi
  $CURL -s -m 8 -o /dev/null -w "%{http_code}" -H "$AUTH" -X PUT "$CTRL/proxies/$(enc "$1")" -H 'Content-Type: application/json' -d "{\"name\":\"$2\"}" 2>/dev/null
}

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

# 日志自限容
if [ -f "$LOG" ]; then
  SZ=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  [ "$SZ" -gt 204800 ] && { tail -60 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }
fi

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
  if [ -n "$AI_NOW" ]; then
    AI_EFF=$(eff_node "$AI_GROUP")
    if match_patterns "$AI_EFF" "$AI_BAD_NODES"; then
      if [ "$(put "$AI_GROUP" "$AI_FALLBACK_GROUP")" = "204" ]; then
        log "FIX: $AI_GROUP 从「$AI_NOW」(实际出口「$AI_EFF」) 复原为「$AI_FALLBACK_GROUP」（该出口不可信）"
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
  if [ -n "$NODE_NOW" ]; then
    NODE_EFF=$(eff_node "$POOL_GROUP")
    if match_patterns "$NODE_EFF" "$POOL_BLOCKED_NODES"; then
      if [ "$(put "$POOL_GROUP" "$POOL_FALLBACK_GROUP")" = "204" ]; then
        log "FIX: $POOL_GROUP 从「$NODE_NOW」(实际出口「$NODE_EFF」) 复原为「$POOL_FALLBACK_GROUP」"
      else
        log "ERROR: 切回 $POOL_FALLBACK_GROUP 失败（控制 API 拒绝）"
      fi
    fi
  fi
fi

# ---------- 3.5) 通用出口健康守卫 ----------
# 节点会劣化（表现为全站超时）。按真实出口耗时判定，超过阈值就复位到自动选择组。
if [ -n "$POOL_GROUP" ] && [ -n "$POOL_FALLBACK_GROUP" ]; then
  T1=$($CURL -s -m 12 -o /dev/null -w "%{time_total}" -x "$PROXY" "$PROBE_URL" 2>/dev/null)
  T2=$($CURL -s -m 12 -o /dev/null -w "%{time_total}" -x "$PROXY" "$PROBE_URL" 2>/dev/null)
  if [ -n "$T1" ] && [ -n "$T2" ]; then
    MS=$(echo "$T1 $T2" | awk '{t+=($1>$2?$1:$2)} END{printf "%.1f", t/2}')
    if ge_sec "$MS" "$EXIT_MAX_SEC"; then
      if [ "$(put "$POOL_GROUP" "$POOL_FALLBACK_GROUP")" = "204" ]; then
        log "FIX: 通用出口耗时 ${MS}s（>${EXIT_MAX_SEC}s，疑似节点劣化），复位为「$POOL_FALLBACK_GROUP」"
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
  C1=$($CURL -s -m 15 -o /dev/null --max-filesize 131072 -w "%{time_total}" -x "$PROXY" "$CLEAN_PROBE_URL" 2>/dev/null)
  C2=$($CURL -s -m 15 -o /dev/null --max-filesize 131072 -w "%{time_total}" -x "$PROXY" "$CLEAN_PROBE_URL" 2>/dev/null)
  [ -z "$C1" ] && [ -z "$C2" ] && { echo "99"; return; }
  echo "$C1 $C2" | awk '{t+=($1>$2?$1:$2)} END{printf "%.1f", t/2}'
}
clean_exit_bad() {
  MS=$(clean_exit_ms)
  ge_sec "$MS" "$CLEAN_EXIT_MAX_SEC"
}
if [ -n "$CLEAN_GROUP" ] && [ -n "$CL_CANDIDATES" ]; then
  CUR_CL=$(grp "$CLEAN_GROUP")
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
  if ! $NFT list table inet $t >/dev/null 2>&1; then
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
if [ -n "$AI_FALLBACK_GROUP" ] && ! grep -q "name: $AI_FALLBACK_GROUP" "$RUNTIME_DIR/config.yaml" 2>/dev/null; then
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
[ -n "$AVAIL" ] && [ "$AVAIL" -lt "$MEM_LOW_MB" ] && log "WARN: 可用内存仅 ${AVAIL}MB（低于 ${MEM_LOW_MB}MB 阈值，注意 OOM 风险）"

# /tmp 是内存盘，一旦被写满会连锁 OOM。超阈值就清掉已知的临时大文件。
TMPK=$(df -k /tmp 2>/dev/null | tail -1 | awk '{print $3}')
TMPT=$(df -k /tmp 2>/dev/null | tail -1 | awk '{print $2}')
if [ -n "$TMPK" ] && [ -n "$TMPT" ] && [ "$TMPT" -gt 0 ]; then
  TMPP=$((TMPK * 100 / TMPT))
  if [ "$TMPP" -ge "$TMPFS_WARN_PCT" ]; then
    log "WARN: /tmp 内存盘已用 ${TMPP}%（${TMPK}K/${TMPT}K），接近撑爆会 OOM 并触发看门狗重启"
    for f in $TMPFS_CLEAN_FILES; do
      [ -z "$f" ] && continue
      [ -e "$f" ] || continue
      if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: 本应清理 /tmp 临时大文件 $f"
      else
        rm -rf "$f" 2>/dev/null
        log "FIX: 已清理 /tmp 临时大文件 $f"
      fi
    done
    TMPK2=$(df -k /tmp 2>/dev/null | tail -1 | awk '{print $3}')
    log "INFO: /tmp 清理后占用 ${TMPK2}K/${TMPT}K"
  fi
fi

# cron lifeline: start.sh stop 会重写 crontab 并删掉 legacy 看门狗行,这里补回去
if [ -n "$LEGACY_WD" ] && [ -f "$LEGACY_WD" ]; then
  if ! grep -q "$(basename "$LEGACY_WD")" "$CRON_FILE" 2>/dev/null; then
    if [ "$DRY_RUN" = "1" ]; then
      log "DRY-RUN: 本应补回 legacy 看门狗 cron 行"
    else
      echo "* * * * * /bin/ash $LEGACY_WD shellcrash #ShellCrash保守模式守护进程" >> "$CRON_FILE"
      crontab "$CRON_FILE" 2>/dev/null
      log "FIX: restored legacy watchdog cron line"
    fi
  fi
fi
exit 0
