#!/bin/sh
# ============================================================================
# bulk-guard.sh —— 「大流量」策略组的带宽守卫
#
# 背景：mihomo 的 url-test / fallback 只测「首包延迟」，不测吞吐。
#   实测 /proxies/<节点>/delay 请求 3MB 文件只花 233ms（与 204 探测几乎一样），
#   正文根本没有传 —— 所以「公共池跑不满就切回机场」只能由脚本按真实下载速率判断。
#
# 组内只有两个候选：公共池（默认）/ 机场池，名字由 device.conf 指定。
# 公共池本身是一个 url-test 组；轮换时脚本会把它钉到某个节点（mihomo 的
# 控制 API 只能钉、不能解钉），所以启用轮换后「按延迟自动选」由本脚本的
# 吞吐缓存接管，直到核心重启把 fixed 清掉。
#
# 判定策略：
#   1) 组空闲时：每 PROBE_INTERVAL 秒下载 PROBE_BYTES 字节探测文件（走本组），
#      低于 MIN_BPS 就切机场。探测「跑满超时但收到了数据」按实测速率算慢，
#      不再当成无效样本 —— 否则 90 KB/s 以下的节点会永远被判成「探测无效」。
#   2) 组有连接且在传：按 connection id 求**正增量之和**（旧连接关闭不会
#      把总和拉低，Telegram 多连接重连也不会被误判成暂停）；连续两个
#      LIVE_SAMPLE_SEC 窗口低于 LIVE_MIN_BPS 才动。第一个窗口慢、第二个
#      窗口 0 字节按「停滞」处理；两个窗口都 0 才按「暂停」放过。
#   3) 确认为慢：先在公共池内部按吞吐缓存从快到慢改试，每个下载会话最多
#      MAX_TRY 个候选（切换会断流，所以有上限）；每个候选给 SETTLE_SEC
#      重连时间，再采样 LIVE_SAMPLE_SEC 真实速率。
#   4) 候选都跑不满（或没有候选）：切机场，停留 RETURN_COOLDOWN 秒；
#      之后连续 IDLE_SWITCH 秒没有「在传」的连接，就切回公共池，并钉住
#      缓存里吞吐最好的节点。
#   5) 公共池和机场都慢：判定为源站/上传方慢，不再在两个池之间来回切。
#
# 为什么不在有连接时跑探测下载：探测流量会和下载抢带宽，把好节点误判成坏节点。
# 为什么切回公共池要等空闲：切组 = 断流；空闲时切没有代价。
#
# 用法：
#   sh bulk-guard.sh              # 正常执行（cron 用，建议每 3 分钟）
#   sh bulk-guard.sh --dry-run    # 只报告，不切组（也不做轮换测量）
#   sh bulk-guard.sh --status     # 打印当前判定、缓存与已试节点
#
# 需要的配置（device.conf 或同名环境变量）：
#   BULK_GROUP / BULK_PUBLIC / BULK_AIRPORT
# 可选项见下面的默认值。
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
_OPS_VARS="CRASHDIR RUNTIME_DIR CTRL_HOST CTRL_PORT PROXY_PORT API_CFG BULK_GROUP BULK_PUBLIC BULK_AIRPORT BULK_PROBE_URL BULK_PROBE_BYTES BULK_MIN_BPS BULK_PROBE_INTERVAL BULK_COOLDOWN BULK_STATE BULK_LOG BULK_LIVE_MIN_BPS BULK_LIVE_SAMPLE_SEC BULK_MAX_TRY BULK_SPEED_TTL BULK_SETTLE_SEC BULK_IDLE_SWITCH BULK_RETURN_COOLDOWN BULK_SPEED_STATE BULK_TRIED BULK_LOCK BULK_PROBE_MIN_BYTES"
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
# 低于这个字节数说明响应体根本不是测速文件（错误页），本次不判定。
PROBE_MIN_BYTES="${BULK_PROBE_MIN_BYTES:-65536}"
# 阈值按 4MB 探测校准（2026-10-22 同一公共节点实测）：
#   2MB 1.19 MB/s、4MB 1.65 MB/s、8MB 2.07 MB/s、20MB 2.67 MB/s
#   —— 小样本被 TCP 慢启动 + 300–500ms RTT 拖低，2MB 会低估约一倍。
# 4MB 的实测值约为持续速率的 0.62 倍，所以 800 KB/s ≈ 持续 10 Mbps：
# 够 1080p 播放与常规下载；低于它切回机场。
MIN_BPS="${BULK_MIN_BPS:-800000}"
# 两小时一次：每次 4MB，公共池每天最多被探测掉约 48MB。
PROBE_INTERVAL="${BULK_PROBE_INTERVAL:-7200}"
# 有活跃连接时的爬速下限：连续两个窗口都低于 200 KB/s 才动。
LIVE_MIN_BPS="${BULK_LIVE_MIN_BPS:-200000}"
LIVE_SAMPLE_SEC="${BULK_LIVE_SAMPLE_SEC:-25}"
# 每个下载会话最多在公共池内部改试几个节点。切换 = 断流，所以有上限；
# 两个候选能覆盖「当前节点最差、缓存里还有更好的」绝大多数情况。
MAX_TRY="${BULK_MAX_TRY:-2}"
# 节点吞吐缓存（用用户当前下载的增速测，不额外发探测流量）。
SPEED_TTL="${BULK_SPEED_TTL:-3600}"
# 切到新节点后给下载重连/爬速的时间，再开始采样。
SETTLE_SEC="${BULK_SETTLE_SEC:-20}"
# 机场 → 公共：连续空闲这么久（没有正在传的连接）才回切。
IDLE_SWITCH="${BULK_IDLE_SWITCH:-300}"
# 公共 → 机场：最少停留这么久再考虑回切，避免在两个池之间来回抖。
RETURN_COOLDOWN="${BULK_RETURN_COOLDOWN:-${BULK_COOLDOWN:-600}}"

STATE="${BULK_STATE:-$RUNTIME_DIR/.bulk_guard_state}"
SPEED="${BULK_SPEED_STATE:-$RUNTIME_DIR/.bulk_guard_speed}"
TRIED="${BULK_TRIED:-$RUNTIME_DIR/.bulk_guard_tried}"
LOCK="${BULK_LOCK:-$RUNTIME_DIR/.bulk_guard.lock}"
LOG="${BULK_LOG:-$RUNTIME_DIR/bulk-guard.log}"
ALIVE_URL="http://www.gstatic.com/generate_204"

MODE="${1:-}"
DRY_RUN=0
case "$MODE" in
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

api_get() { $CURL -s -m 5 -H "$AUTH" "$CTRL$1" 2>/dev/null; }

grp() {
  api_get "/proxies/$(enc "$1")" \
    | grep -oE '"now":"[^"]*"' | head -1 | sed 's/"now":"//;s/"$//'
}
grp_fixed() {
  api_get "/proxies/$(enc "$1")" \
    | grep -oE '"fixed":"[^"]*"' | head -1 | sed 's/"fixed":"//;s/"$//'
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

# ---- 状态文件：last_probe / cooldown_until / last_moving / fails -------------
state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -1; }
state_set() {
  [ -f "$STATE" ] || : > "$STATE"
  # 值里可能有 | & 等字符（节点名来自控制 API），不能拼进 sed 的 s|..|..|。
  # 先写临时文件再原子替换，值按字面写入。
  _tmp="$STATE.tmp.$$"
  { grep -v "^$1=" "$STATE" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } > "$_tmp" &&
    mv -f "$_tmp" "$STATE" || rm -f "$_tmp"
}

# ---- /connections 解析（无 jq/python）--------------------------------------
conn_raw() { $CURL -s -m 6 -H "$AUTH" "$CTRL/connections" 2>/dev/null; }
# 走本组的活跃连接数
conn_used() {
  conn_raw | sed 's/},{/}\n{/g' | grep -cF "\"$GROUP\"" 2>/dev/null | head -1
}
# 把走本组的连接写成「<id> <download>」快照，供两次采样求增量
snap_group() {
  conn_raw | sed 's/},{/}\n{/g' | grep -F "\"$GROUP\"" 2>/dev/null \
    | sed -n 's/.*"id":"\([^"]*\)".*"download":\([0-9]*\).*/\1 \2/p' > "$1"
}
# 两次快照之间按 connection id 求正增量之和（关掉的连接不产生负增量）。
# 结果放在 S_BPS / S_N1 / S_N2。
sample_rate() {
  _sa="$RUNTIME_DIR/.bulk_guard_snap.$$.a"
  _sb="$RUNTIME_DIR/.bulk_guard_snap.$$.b"
  snap_group "$_sa"
  sleep "$1"
  snap_group "$_sb"
  S_N1=$(wc -l < "$_sa" 2>/dev/null | tr -d ' ')
  S_N1=${S_N1:-0}
  S_N2=$(wc -l < "$_sb" 2>/dev/null | tr -d ' ')
  S_N2=${S_N2:-0}
  if [ "$S_N1" -eq 0 ] && [ "$S_N2" -eq 0 ]; then
    S_BPS=0
  else
    S_BPS=$(awk -v s="$1" \
      'NR==FNR{a[$1]=$2;next} ($1 in a){d=$2-a[$1]; if(d>0)t+=d} END{printf "%d", t/s}' \
      "$_sa" "$_sb" 2>/dev/null)
    S_BPS=${S_BPS:-0}
  fi
  rm -f "$_sa" "$_sb"
}

# ---- 节点吞吐缓存：epoch|bps|node ------------------------------------------
speed_set() {
  [ -f "$SPEED" ] || : > "$SPEED"
  awk -F'|' -v n="$1" -v now="$NOW_TS" -v ttl="$SPEED_TTL" \
    'now-$1<=ttl && $3!=n' "$SPEED" > "$SPEED.tmp" 2>/dev/null
  echo "$NOW_TS|$2|$1" >> "$SPEED.tmp"
  mv "$SPEED.tmp" "$SPEED"
}
# 缓存里还有效的节点，按吞吐从高到低
speed_list() {
  [ -f "$SPEED" ] || return 0
  awk -F'|' -v now="$NOW_TS" -v ttl="$SPEED_TTL" \
    'now-$1<=ttl && $2>0 {print $2"|"$3}' "$SPEED" 2>/dev/null \
    | sort -t'|' -k1,1nr | cut -d'|' -f2-
}

# ---- 每个下载会话「已经改试过」的节点 --------------------------------------
tried_has() { [ -f "$TRIED" ] && grep -Fxq "$1" "$TRIED" 2>/dev/null; }
tried_add() { echo "$1" >> "$TRIED"; }
tried_count() {
  if [ -f "$TRIED" ]; then wc -l < "$TRIED" | tr -d ' '; else echo 0; fi
}
tried_reset() { : > "$TRIED"; }

# ---- 公共池成员 / 存活检查 ------------------------------------------------
pool_nodes() {
  api_get "/proxies/$(enc "$PUBLIC")" \
    | sed -n 's/.*"all":\[\([^]]*\)\].*/\1/p' \
    | tr ',' '\n' | sed 's/^"//; s/"$//'
}
node_alive() {
  _c=$($CURL -s -m 6 -o /dev/null -w "%{http_code}" -H "$AUTH" -G \
    --data-urlencode "url=$ALIVE_URL" --data-urlencode "timeout=2500" \
    "$CTRL/proxies/$(enc "$1")/delay" 2>/dev/null)
  [ "$_c" = "200" ]
}
# 走本组的存活检查：能拿到 200（delay 结果）返回 0
group_alive() {
  _c=$($CURL -s -m 8 -o /dev/null -w "%{http_code}" -H "$AUTH" -G \
    --data-urlencode "url=$ALIVE_URL" --data-urlencode "timeout=5000" \
    "$CTRL/proxies/$(enc "$GROUP")/delay" 2>/dev/null)
  [ "$_c" = "200" ]
}

# 真实吞吐（bytes/sec）：走本组下载 PROBE_BYTES 字节，取 curl 的平均速率。
# 返回 -1 只在「响应码不对 / 响应体根本不是文件」时，调用方不据此切组。
# 跑满超时但收到了数据 = 节点慢，按实测速率返回 —— 这正是老版本判不出的场景。
probe_bps() {
  _out=$($CURL -s -m 40 --proxy "$PROXY" -r "0-$((PROBE_BYTES - 1))" -o /dev/null \
    -w '%{http_code} %{size_download} %{speed_download} %{time_total}' "$PROBE_URL" 2>/dev/null)
  _code=$(echo "$_out" | cut -d' ' -f1)
  _size=$(echo "$_out" | cut -d' ' -f2)
  _spd=$(echo "$_out" | cut -d' ' -f3)
  _time=$(echo "$_out" | cut -d' ' -f4)
  case "$_code" in 200|206) ;; *) echo -1; return ;; esac
  case "$_size" in ''|*[!0-9]*) echo -1; return ;; esac
  [ "$_size" -lt "$PROBE_MIN_BYTES" ] && { echo -1; return; }
  if [ "$_size" -lt $((PROBE_BYTES * 9 / 10)) ]; then
    # 没拿满：只有「跑满超时」才算测到了真实速率；提前断流按无效处理。
    case "$_time" in ''|*[!0-9.]*) echo -1; return ;; esac
    _ti=$(echo "$_time" | cut -d. -f1)
    [ "$_ti" -ge 38 ] || { echo -1; return; }
  fi
  case "$_spd" in ''|*[!0-9.]*) echo 0 ;; *) echo "$_spd" | cut -d. -f1 ;; esac
}

# 按缓存从快到慢列出候选公共节点（排除当前节点与本会话已试过的）
candidate_list() {
  _cur="$1"
  {
    speed_list
    pool_nodes
  } | awk '!seen[$0]++' | while IFS= read -r _n; do
    [ -z "$_n" ] && continue
    [ "$_n" = "$_cur" ] && continue
    tried_has "$_n" && continue
    echo "$_n"
  done
}

# 找一个能用的公共节点（缓存顺序优先），不看「本会话已试」——
# 钉住的节点死掉时必须无条件换一个，否则 fixed 会让 URLTest 无法自愈。
pick_live_node() {
  _ex="$1"
  {
    speed_list
    pool_nodes
  } | awk '!seen[$0]++' | while IFS= read -r _n; do
    [ -z "$_n" ] && continue
    [ "$_n" = "$_ex" ] && continue
    if node_alive "$_n"; then
      echo "$_n"
      break
    fi
  done
}

# 公共池被钉住后 URLTest 不再自动切换：每轮先确认钉住的节点还活着，
# 死了就换一个活的；全都不活就切机场。未钉住时交给 URLTest，不额外探测。
pool_health() {
  _pin=$(grp_fixed "$PUBLIC")
  [ -n "$_pin" ] || return 0
  node_alive "$_pin" && return 0
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN: 公共池钉住的「$_pin」不可达，将改钉一个可用节点"
    return 0
  fi
  _rep=$(pick_live_node "$_pin")
  if [ -n "$_rep" ]; then
    if [ "$(put "$PUBLIC" "$_rep")" = "204" ]; then
      log "FIX: 公共池钉住的「$_pin」不可达，改钉「$_rep」"
    else
      log "ERROR: 公共池钉住的「$_pin」不可达，改钉「$_rep」被控制 API 拒绝"
    fi
    return 0
  fi
  switch_airport "公共池钉住的「$_pin」不可达且没有可用替代"
  return 1
}

switch_airport() {
  _why="$1"
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN: 将把「$GROUP」切到「$AIRPORT」（$_why）"
    return 0
  fi
  if [ "$(put "$GROUP" "$AIRPORT")" = "204" ]; then
    state_set cooldown_until $((NOW_TS + RETURN_COOLDOWN))
    state_set fails 0
    log "FIX: 「$GROUP」切到「$AIRPORT」：$_why（机场停留 ${RETURN_COOLDOWN}s）"
  else
    log "ERROR: 切到「$AIRPORT」被控制 API 拒绝：$_why"
  fi
}

# 确认为慢：先在公共池内部按缓存改试，最多 MAX_TRY 个；都不行再切机场。
handle_slow() {
  _bps="$1"
  _cur=$(grp "$PUBLIC")
  [ -n "$_cur" ] || _cur="?"
  _tried=$(tried_count)
  _n=0
  _last_bps="$_bps"
  _last_node="$_cur"
  _cands="$RUNTIME_DIR/.bulk_guard_cands.$$"
  candidate_list "$_cur" > "$_cands"
  while IFS= read -r _cand; do
    [ -z "$_cand" ] && continue
    [ $((_tried + _n)) -ge "$MAX_TRY" ] && break
    if ! node_alive "$_cand"; then
      log "INFO: 候选「$_cand」不可达，跳过"
      continue
    fi
    _n=$((_n + 1))
    if [ "$DRY_RUN" = "1" ]; then
      log "DRY-RUN: 「$_cur」$((_bps / 1024)) KB/s 低于阈值，将改试「$_cand」（第 $((_tried + _n)) 次）"
      rm -f "$_cands"
      return 0
    fi
    if [ "$(put "$PUBLIC" "$_cand")" != "204" ]; then
      log "ERROR: 把公共池钉到「$_cand」被控制 API 拒绝"
      continue
    fi
    tried_add "$_cand"
    log "FIX: 公共池「$_cur」$((_bps / 1024)) KB/s < $((LIVE_MIN_BPS / 1024)) KB/s，改试「$_cand」（第 $((_tried + _n)) 次）"
    sleep "$SETTLE_SEC"
    sample_rate "$LIVE_SAMPLE_SEC"
    _r=$S_BPS
    [ "$S_N2" -eq 0 ] && _r=0
    speed_set "$_cand" "$_r"
    if [ "$_r" -ge "$LIVE_MIN_BPS" ]; then
      log "INFO: 「$_cand」实测 $((_r / 1024)) KB/s，留在上面"
      rm -f "$_cands"
      return 0
    fi
    _last_bps="$_r"
    _last_node="$_cand"
  done < "$_cands"
  rm -f "$_cands"
  switch_airport "公共池候选都跑不满（「$_last_node」$((_last_bps / 1024)) KB/s）"
}

idle_probe() {
  [ $((NOW_TS - LAST)) -ge "$PROBE_INTERVAL" ] || return 0
  _bps=$(probe_bps)
  if [ "$_bps" -lt 0 ]; then
    log "WARN: 探测无效（响应码/字节数不符），本次不判定（下轮重试）"
    return 0
  fi
  state_set last_probe "$NOW_TS"
  _cur=$(grp "$PUBLIC")
  [ -n "$_cur" ] && speed_set "$_cur" "$_bps"
  log "INFO: 空闲探测 $((_bps / 1024)) KB/s（阈值 $((MIN_BPS / 1024)) KB/s，节点「${_cur:-?}」）"
  if [ "$_bps" -lt "$MIN_BPS" ]; then
    switch_airport "空闲探测 $((_bps / 1024)) KB/s 低于阈值"
  fi
}

# 同一时间只允许一个实例：整轮最坏要跑两分多钟，3 分钟 cron 可能压边。
acquire_lock() {
  if [ -d "$LOCK" ]; then
    _lp=$(cat "$LOCK/pid" 2>/dev/null)
    _lt=$(cat "$LOCK/ts" 2>/dev/null)
    if [ -n "$_lp" ] && kill -0 "$_lp" 2>/dev/null \
       && [ -n "$_lt" ] && [ $((NOW_TS - _lt)) -lt 600 ]; then
      exit 0
    fi
    rm -f "$LOCK/pid" "$LOCK/ts" 2>/dev/null
    rmdir "$LOCK" 2>/dev/null
  fi
  mkdir "$LOCK" 2>/dev/null || exit 0
  echo $$ > "$LOCK/pid"
  echo "$NOW_TS" > "$LOCK/ts"
  trap 'rm -f "$LOCK/pid" "$LOCK/ts" 2>/dev/null; rmdir "$LOCK" 2>/dev/null; rm -f "$RUNTIME_DIR"/.bulk_guard_snap.$$.* "$RUNTIME_DIR"/.bulk_guard_cands.$$ 2>/dev/null' EXIT INT TERM HUP
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
LAST_MOVING=$(state_get last_moving); LAST_MOVING=${LAST_MOVING:-0}

if [ "$MODE" = "--status" ]; then
  echo "组: $GROUP"
  echo "当前: $NOW"
  echo "公共池: $PUBLIC（钉住: $(grp_fixed "$PUBLIC")）"
  echo "阈值: $((MIN_BPS / 1024)) KB/s（空闲探测 ${PROBE_BYTES}B，每 ${PROBE_INTERVAL}s 一次）"
  echo "爬速下限: $((LIVE_MIN_BPS / 1024)) KB/s（活跃连接时 2×${LIVE_SAMPLE_SEC}s 采样）"
  echo "每会话最多改试: $MAX_TRY 个公共节点（已试 $(tried_count)）"
  echo "候选冷却: ${SETTLE_SEC}s；节点缓存 TTL: ${SPEED_TTL}s"
  echo "回切: 机场停留 ${RETURN_COOLDOWN}s 且空闲 ${IDLE_SWITCH}s"
  echo "冷却到: $CU（现在 $NOW_TS）"
  echo "上次探测: $LAST"
  echo "连续失败: $FAILS"
  if [ -f "$SPEED" ]; then
    echo "节点缓存:"
    sed 's/^/  /' "$SPEED"
  fi
  if [ -f "$TRIED" ]; then
    echo "本会话已试:"
    sed 's/^/  /' "$TRIED"
  fi
  exit 0
fi

acquire_lock

# 两次下载之间隔了 IDLE_SWITCH 以上，就算新会话：清空「已试」。
if [ $((NOW_TS - LAST_MOVING)) -gt "$IDLE_SWITCH" ]; then
  tried_reset
fi

if [ "$NOW" = "$PUBLIC" ]; then
  USED=$(conn_used); USED=${USED:-0}
  # 连接数不等于在传：Telegram 会一直挂着长连接，空闲时也要按「空闲」处理，
  # 否则探测永远轮不到。用 5 秒的字节增量判断是否真的在传。
  MOVING=0
  if [ "$USED" -gt 0 ]; then
    sample_rate 5
    [ "$S_BPS" -gt 0 ] && MOVING=1
  fi
  if [ "$MOVING" = "1" ]; then
    state_set last_moving "$NOW_TS"
    if ! group_alive; then
      switch_airport "公共池 $USED 条活跃连接下存活检查失败"
    else
      # 连续两个窗口都低于下限才算慢；0 字节窗口按「停滞/暂停」区分。
      _slow=0
      _w=0
      _r1=0
      _rlast=0
      while [ "$_w" -lt 2 ]; do
        _w=$((_w + 1))
        sample_rate "$LIVE_SAMPLE_SEC"
        _r=$S_BPS
        # 第二次快照已经没有连接 = 下载已经结束，不要据此切组
        if [ "$S_N2" -eq 0 ]; then
          _slow=0
          break
        fi
        if [ "$_r" -eq 0 ]; then
          # 0 字节：只有「上一窗在传但低于下限」才算停滞；两个窗口都 0 按暂停放过
          if [ "$_w" -eq 2 ] && [ "$_r1" -gt 0 ] && [ "$_r1" -lt "$LIVE_MIN_BPS" ]; then
            _slow=1
            _rlast="$_r1"
          else
            _slow=0
          fi
          break
        fi
        _rlast="$_r"
        if [ "$_r" -ge "$LIVE_MIN_BPS" ]; then
          _slow=0
          break
        fi
        _slow=1
        [ "$_w" -eq 1 ] && _r1="$_r"
      done
      if [ "$_slow" = "1" ]; then
        _cur=$(grp "$PUBLIC")
        [ -n "$_cur" ] && speed_set "$_cur" "$_rlast"
        handle_slow "$_rlast"
      fi
    fi
  else
    # 钉住的节点死了 URLTest 不会自愈；只在空闲时查，避免把忙节点的 504 当成死亡。
    if pool_health; then idle_probe; fi
  fi
else
  # 当前在机场（或用户手选的其它成员）：空闲够久才切回公共池
  USED=$(conn_used); USED=${USED:-0}
  MOVING=0
  if [ "$USED" -gt 0 ]; then
    sample_rate 5
    [ "$S_BPS" -gt 0 ] && MOVING=1
  fi
  if [ "$MOVING" = "1" ]; then
    state_set last_moving "$NOW_TS"
  else
    LAST_MOVING=$(state_get last_moving); LAST_MOVING=${LAST_MOVING:-0}
    if [ $((NOW_TS - LAST_MOVING)) -ge "$IDLE_SWITCH" ] && [ "$NOW_TS" -ge "$CU" ]; then
      _best=$(speed_list | head -1)
      if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: 将切回「$PUBLIC」并钉住「${_best:-不钉}」"
      else
        [ -n "$_best" ] && put "$PUBLIC" "$_best" >/dev/null
        if [ "$(put "$GROUP" "$PUBLIC")" = "204" ]; then
          tried_reset
          state_set fails 0
          _msg=""
          [ -n "$_best" ] && _msg="（钉住「$_best」）"
          log "INFO: 机场已空闲 $(( (NOW_TS - LAST_MOVING) / 60 )) 分钟，切回公共池$_msg"
        else
          log "ERROR: 切回「$PUBLIC」被控制 API 拒绝"
        fi
      fi
    fi
  fi
fi
