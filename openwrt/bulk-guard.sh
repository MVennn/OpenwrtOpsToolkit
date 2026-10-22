#!/bin/sh
# ============================================================================
# bulk-guard.sh —— 「大流量」策略组的带宽守卫
#
# 背景：mihomo 的 url-test / fallback 只测「首包延迟」，不测吞吐。
#   实测 /proxies/<节点>/delay 请求 3MB 文件只花 233ms（与 204 探测几乎一样），
#   正文根本没有传 —— 所以「公共池跑不满就切回机场」只能由脚本按真实下载速率判断。
#
# 组内只有两个候选：公共池（默认）/ 机场池，名字由 device.conf 指定。
#
# 判定策略（刻意保守）：
#   1) 组空闲时：每 PROBE_INTERVAL 秒下载 PROBE_BYTES 字节探测文件（走本组），
#      低于 MIN_BPS 就切机场并冷却 COOLDOWN 秒。这是「跑不满」的主要判据。
#   2) 组有连接且**在传**（5s 内字节有增长）时：先判存活（5s 内能否拿到 204），
#      死了立刻切；活着则采样真实速率 —— 连续两个 30s 窗口都低于
#      LIVE_MIN_BPS 才切。0 字节的窗口不算（暂停 / 已传完但连接未关）。
#      连接挂着但 5s 内没有字节增长（Telegram 空闲长连接）按空闲处理。
#   3) 组在机场时：冷却结束且无活跃连接 → 切回公共池，并立即首测。
#
# 为什么不在有连接时跑探测下载：探测流量会和下载抢带宽，把好节点误判成坏节点。
# 为什么切回公共池要等空闲：切组 = 断流；空闲时切没有代价。
# （判为「爬速」时例外：反正已经跑不动，切换代价小于继续卡。）
#
# 用法：
#   sh bulk-guard.sh              # 正常执行（cron 用）
#   sh bulk-guard.sh --dry-run    # 只报告，不切组
#   sh bulk-guard.sh --status     # 打印当前组状态与判定参数
#
# 需要的配置（device.conf 或同名环境变量）：
#   BULK_GROUP / BULK_PUBLIC / BULK_AIRPORT
# 可选项见文件末尾的默认值。
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
_OPS_VARS="CRASHDIR RUNTIME_DIR CTRL_HOST CTRL_PORT PROXY_PORT API_CFG BULK_GROUP BULK_PUBLIC BULK_AIRPORT BULK_PROBE_URL BULK_PROBE_BYTES BULK_MIN_BPS BULK_PROBE_INTERVAL BULK_COOLDOWN BULK_STATE BULK_LOG"
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
API_CFG="${API_CFG:-$CRASHDIR/configs/ShellCrash.cfg}"

GROUP="${BULK_GROUP:-}"
PUBLIC="${BULK_PUBLIC:-}"
AIRPORT="${BULK_AIRPORT:-}"

# 探测文件：这个域应在 rules 里固定指向本组，探测才会走本组。
# 用 OVH 的测速文件 + Range 只取前 4MB —— Cloudflare 的 __down 在公共节点上
# 会被限流成 403（2026-10-22 实测），403 的「速度」会被误判成节点慢。
PROBE_BYTES="${BULK_PROBE_BYTES:-4000000}"
PROBE_URL="${BULK_PROBE_URL:-https://proof.ovh.net/files/10Mb.dat}"
# 阈值按 4MB 探测校准（2026-10-22 同一公共节点实测）：
#   2MB 1.19 MB/s、4MB 1.65 MB/s、8MB 2.07 MB/s、20MB 2.67 MB/s
#   —— 小样本被 TCP 慢启动 + 300–500ms RTT 拖低，2MB 会低估约一倍。
# 4MB 的实测值约为持续速率的 0.62 倍，所以 800 KB/s ≈ 持续 10 Mbps：
# 够 1080p 播放与常规下载；低于它切回机场。
MIN_BPS="${BULK_MIN_BPS:-800000}"
# 两小时一次：每次 4MB，公共池每天最多被探测掉约 48MB。
PROBE_INTERVAL="${BULK_PROBE_INTERVAL:-7200}"
# 有活跃连接时的爬速下限：连续两个 30s 窗口都低于 200 KB/s 才切。
# 0 字节的窗口跳过（暂停 / 已传完但连接未关）。
LIVE_MIN_BPS="${BULK_LIVE_MIN_BPS:-200000}"
LIVE_SAMPLE_SEC="${BULK_LIVE_SAMPLE_SEC:-30}"
# 切回机场后至少停留一小时再试公共池，避免在坏节点之间来回抖。
COOLDOWN="${BULK_COOLDOWN:-3600}"

STATE="${BULK_STATE:-$RUNTIME_DIR/.bulk_guard_state}"
LOG="${BULK_LOG:-$RUNTIME_DIR/bulk-guard.log}"
ALIVE_URL="http://www.gstatic.com/generate_204"

DRY_RUN=0
case "${1:-}" in
  --dry-run|-n) DRY_RUN=1 ;;
esac

mkdir -p "$RUNTIME_DIR" 2>/dev/null
CURL="${CURL:-/usr/bin/curl}"
[ -x "$CURL" ] || CURL=curl
CTRL="http://$CTRL_HOST:$CTRL_PORT"
PROXY="http://127.0.0.1:$PROXY_PORT"

API_SECRET=$(sed -n 's/^secret=//p' "$API_CFG" 2>/dev/null | head -1)
AUTH="Authorization: Bearer $API_SECRET"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() {
  echo "$(ts) $*" >> "$LOG"
  case "$*" in
    *FIX*|*ALERT*|*ERROR*|*WARN*) logger -t bulk-guard -p daemon.warn "$*" 2>/dev/null ;;
  esac
}
enc() { echo "$1" | sed 's/ /%20/g'; }

grp() {
  $CURL -s -m 5 -H "$AUTH" "$CTRL/proxies/$(enc "$1")" 2>/dev/null \
    | grep -oE '"now":"[^"]*"' | head -1 | sed 's/"now":"//;s/"$//'
}
put() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN: 将把「$1」切到「$2」"
    echo 204
    return 0
  fi
  $CURL -s -m 8 -o /dev/null -w "%{http_code}" -H "$AUTH" \
    -X PUT "$CTRL/proxies/$(enc "$1")" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$2\"}" 2>/dev/null
}

# ---- 状态文件：fails / last_probe / cooldown_until -------------------------
state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -1; }
state_set() {
  [ -f "$STATE" ] || : > "$STATE"
  if grep -q "^$1=" "$STATE" 2>/dev/null; then
    sed -i "s|^$1=.*|$1=$2|" "$STATE"
  else
    echo "$1=$2" >> "$STATE"
  fi
}

# ---- /connections 解析（无 jq/python，用 sed 拆对象）----------------------
conn_raw() { $CURL -s -m 6 -H "$AUTH" "$CTRL/connections" 2>/dev/null; }
# 走本组的活跃连接数
conn_used() {
  conn_raw | sed 's/},{/}\n{/g' | grep -cF "\"$GROUP\"" 2>/dev/null | head -1
}
# 走本组的累计下载字节（两次采样相减得速率）
conn_bytes() {
  conn_raw | sed 's/},{/}\n{/g' | grep -F "\"$GROUP\"" 2>/dev/null \
    | grep -o '"download":[0-9]*' | cut -d: -f2 \
    | awk '{s+=$1} END{printf "%d", s+0}'
}

# 走本组的存活检查：能拿到 200（delay 结果）返回 0
group_alive() {
  _code=$($CURL -s -m 8 -o /dev/null -w "%{http_code}" -H "$AUTH" -G \
    --data-urlencode "url=$ALIVE_URL" --data-urlencode "timeout=5000" \
    "$CTRL/proxies/$(enc "$GROUP")/delay" 2>/dev/null)
  [ "$_code" = "200" ]
}

# 真实吞吐（bytes/sec）：走本组下载 PROBE_BYTES 字节，取 curl 的平均速率。
# 响应码不是 200/206、或收到的字节不足 90% 时返回 -1（测量无效，调用方不据此切组）。
probe_bps() {
  _out=$($CURL -s -m 40 --proxy "$PROXY" -r "0-$((PROBE_BYTES - 1))" -o /dev/null \
    -w '%{http_code} %{size_download} %{speed_download}' "$PROBE_URL" 2>/dev/null)
  _code=$(echo "$_out" | cut -d' ' -f1)
  _size=$(echo "$_out" | cut -d' ' -f2)
  _spd=$(echo "$_out" | cut -d' ' -f3)
  case "$_code" in 200|206) ;; *) echo -1; return ;; esac
  case "$_size" in ''|*[!0-9]*) echo -1; return ;; esac
  [ "$_size" -lt $((PROBE_BYTES * 9 / 10)) ] && { echo -1; return; }
  case "$_spd" in
    ''|*[!0-9.]*) echo 0 ;;
    *) echo "$_spd" | cut -d. -f1 ;;
  esac
}

# 日志自限容（与 guardian.sh 一致）
if [ -f "$LOG" ]; then
  SZ=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  [ "$SZ" -gt 204800 ] && { tail -60 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }
fi

if [ -z "$GROUP" ] || [ -z "$PUBLIC" ] || [ -z "$AIRPORT" ]; then
  log "WARN: 未配置 BULK_GROUP / BULK_PUBLIC / BULK_AIRPORT，跳过"
  exit 0
fi

NOW=$(grp "$GROUP")
if [ -z "$NOW" ]; then
  log "WARN: 组「$GROUP」不存在（配置可能回退到基础配置），本次跳过"
  exit 0
fi

NOW_TS=$(date +%s)
CU=$(state_get cooldown_until); CU=${CU:-0}
LAST=$(state_get last_probe); LAST=${LAST:-0}
FAILS=$(state_get fails); FAILS=${FAILS:-0}

if [ "${1:-}" = "--status" ]; then
  echo "组: $GROUP"
  echo "当前: $NOW"
  echo "阈值: $((MIN_BPS / 1024)) KB/s（探测 ${PROBE_BYTES}B，每 ${PROBE_INTERVAL}s 一次）"
  echo "爬速下限: $((LIVE_MIN_BPS / 1024)) KB/s（活跃连接时连续 2×${LIVE_SAMPLE_SEC}s 采样）"
  echo "冷却到: $CU（现在 $NOW_TS）"
  echo "上次探测: $LAST"
  echo "连续失败: $FAILS"
  exit 0
fi

if [ "$NOW" = "$PUBLIC" ]; then
  USED=$(conn_used); USED=${USED:-0}
  # 连接数不等于在传：Telegram 会一直挂着长连接，空闲时也要按「空闲」处理，
  # 否则探测永远轮不到。用 5 秒的累计字节增量判断是否真的在传。
  MOVING=0
  if [ "$USED" -gt 0 ]; then
    _q1=$(conn_bytes); sleep 5; _q2=$(conn_bytes)
    [ $((_q2 - _q1)) -gt 0 ] && MOVING=1
  fi
  if [ "$MOVING" = "1" ]; then
    # 有活跃连接：先判存活；活着再采样真实速率
    if ! group_alive; then
      if [ "$(put "$GROUP" "$AIRPORT")" = "204" ]; then
        state_set cooldown_until $((NOW_TS + COOLDOWN))
        state_set fails 0
        log "FIX: 公共池 $USED 条活跃连接下存活检查失败，切回 $AIRPORT（冷却 ${COOLDOWN}s）"
      else
        log "ERROR: 公共池已失效但切回 $AIRPORT 被控制 API 拒绝"
      fi
    else
      # 连续两个窗口都低于下限才算爬速；0 字节窗口（暂停/已传完）直接放过
      _slow=0
      _i=0
      while [ "$_i" -lt 2 ]; do
        _i=$((_i + 1))
        _b1=$(conn_bytes)
        sleep "$LIVE_SAMPLE_SEC"
        _b2=$(conn_bytes)
        _r=$(( (_b2 - _b1) / LIVE_SAMPLE_SEC ))
        [ "$_r" -lt 0 ] && _r=0
        if [ "$_r" -eq 0 ] || [ "$_r" -ge "$LIVE_MIN_BPS" ]; then
          _slow=0
          break
        fi
        _slow=1
      done
      if [ "$_slow" = "1" ]; then
        if [ "$(put "$GROUP" "$AIRPORT")" = "204" ]; then
          state_set cooldown_until $((NOW_TS + COOLDOWN))
          state_set fails 0
          log "FIX: 公共池 $USED 条活跃连接持续爬速（< $((LIVE_MIN_BPS / 1024)) KB/s），切回 $AIRPORT（冷却 ${COOLDOWN}s）"
        else
          log "ERROR: 爬速但切回 $AIRPORT 被控制 API 拒绝"
        fi
      fi
    fi
  else
    # 空闲：到点就实测吞吐，这是「跑不满」的唯一判据
    if [ $((NOW_TS - LAST)) -ge "$PROBE_INTERVAL" ]; then
      BPS=$(probe_bps)
      if [ "$BPS" -lt 0 ]; then
        log "WARN: 探测无效（响应码/字节数不符），本次不判定（下轮重试）"
      else
        state_set last_probe "$NOW_TS"
        log "INFO: 空闲探测 $((BPS / 1024)) KB/s（阈值 $((MIN_BPS / 1024)) KB/s）"
        if [ "$BPS" -lt "$MIN_BPS" ]; then
          if [ "$(put "$GROUP" "$AIRPORT")" = "204" ]; then
            state_set cooldown_until $((NOW_TS + COOLDOWN))
            state_set fails 0
            log "FIX: 公共池实测 $((BPS / 1024)) KB/s 低于阈值，切回 $AIRPORT（冷却 ${COOLDOWN}s）"
          else
            log "ERROR: 切回 $AIRPORT 失败（控制 API 拒绝）"
          fi
        fi
      fi
    fi
  fi
else
  # 当前在机场（或用户手选的其它成员）：冷却结束且空闲时切回公共池并首测
  if [ "$NOW_TS" -ge "$CU" ] && [ "$(conn_used)" -eq 0 ]; then
    if [ "$(put "$GROUP" "$PUBLIC")" = "204" ]; then
      state_set fails 0
      state_set last_probe "$NOW_TS"
      sleep 2
      BPS=$(probe_bps)
      if [ "$BPS" -lt 0 ]; then
        log "WARN: 已切回公共池，但首测无效（不据此退回）"
      else
        log "INFO: 已切回公共池，首测 $((BPS / 1024)) KB/s"
        if [ "$BPS" -lt "$MIN_BPS" ]; then
          put "$GROUP" "$AIRPORT" >/dev/null
          state_set cooldown_until $((NOW_TS + COOLDOWN))
          log "FIX: 切回后首测仍低于阈值，退回 $AIRPORT（冷却 ${COOLDOWN}s）"
        fi
      fi
    else
      log "ERROR: 切回 $PUBLIC 失败（控制 API 拒绝）"
    fi
  fi
fi
