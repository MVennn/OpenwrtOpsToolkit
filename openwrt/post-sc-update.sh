#!/bin/sh
# post-sc-update.sh —— ShellCrash 官方脚本更新之后，把本地补丁恢复回来并做验收
#
# 背景：ShellCrash 的更新包会整包覆盖 starts/ libs/ tools/ 等目录，
#       你自己打的钩子（改配置的脚本、防火墙补丁、看门狗）会**被静默冲掉**。
#       本脚本在更新之后跑一次：按标记检出被覆盖的文件 → 从备份目录恢复 → 补 cron → 启动 → 验收。
#
# 用法：
#   sh post-sc-update.sh          恢复 + 验收
#   sh post-sc-update.sh check    只检查，不改任何东西
#
# 关键配置（见 conf/device.conf.example）：
#   PATCH_DIR   —— 本地补丁备份目录（默认 $CRASHDIR/local-patches）
#   PATCH_SPEC  —— 要恢复哪些文件、靠什么标记认；格式
#                  "相对CRASHDIR的路径=标记1,标记2"（空格分隔多组，标记之间是「与」关系）
#                  例：starts/你的补丁.sh=标记A,标记B
#   CHECK_GROUP —— 运行态配置里必须出现的策略组名（可选）

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

_OPS_VARS="CRASHDIR RUNTIME_DIR PATCH_DIR PATCH_SPEC CRON_FILE RC_LOCAL GUARDIAN_PATH GUARDIAN_CRON_LINE CRON_WD_LINE CRON_SAVE_LINE CHECK_GROUP RESTART_CORE CORE_BIN CORE_PROC MIXED_PORT PROXY_PORT DIRECT_TEST_HOST PROXY_TEST_URL POST_SC_LOG WARN_INIT_ENABLED"
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
PATCH_DIR="${PATCH_DIR:-$CRASHDIR/local-patches}"
PATCH_SPEC="${PATCH_SPEC:-}"
CRON_FILE="${CRON_FILE:-/etc/crontabs/root}"
RC_LOCAL="${RC_LOCAL:-/etc/rc.local}"
GUARDIAN_PATH="${GUARDIAN_PATH:-$CRASHDIR/guardian.sh}"
GUARDIAN_CRON_LINE="${GUARDIAN_CRON_LINE:-*/5 * * * * /bin/ash $GUARDIAN_PATH #网络守护}"
CRON_WD_LINE="${CRON_WD_LINE:-* * * * * /bin/ash $CRASHDIR/starts/start_legacy_wd.sh shellcrash #ShellCrash保守模式守护进程}"
CRON_SAVE_LINE="${CRON_SAVE_LINE:-*/10 * * * * $CRASHDIR/task/task.sh 106 #运行时自动保存面板配置}"
CHECK_GROUP="${CHECK_GROUP:-}"
RESTART_CORE="${RESTART_CORE:-1}"
CORE_BIN="${CORE_BIN:-$CRASHDIR/CrashCore.raw}"
CORE_PROC="${CORE_PROC:-CrashCore}"
MIXED_PORT="${MIXED_PORT:-7892}"
PROXY_PORT="${PROXY_PORT:-7890}"
DIRECT_TEST_HOST="${DIRECT_TEST_HOST:-www.baidu.com}"
PROXY_TEST_URL="${PROXY_TEST_URL:-https://www.google.com}"
WARN_INIT_ENABLED="${WARN_INIT_ENABLED:-1}"
POST_SC_LOG="${POST_SC_LOG:-/root/post-sc-update.log}"

LOG="$POST_SC_LOG"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
section() { log ""; log "===== $* ====="; }

MODE="${1:-fix}"
TS=$(date +%Y%m%d-%H%M%S)

# 文件是否含全部标记（标记之间是「与」关系）
has_all_markers() {
  _f=$1
  _marks=$2
  [ -f "$_f" ] || return 1
  _old="$IFS"; IFS=","
  for _m in $_marks; do
    [ -z "$_m" ] && continue
    IFS="$_old"
    grep -q "$_m" "$_f" 2>/dev/null || { IFS="$_old"; return 1; }
    IFS=","
  done
  IFS="$_old"
  return 0
}

# 确保 crontab 里有某一行（按关键字判断是否已存在）
ensure_cron() {
  _kw=$1
  _line=$2
  [ -z "$_line" ] && return 0
  if grep -q "$_kw" "$CRON_FILE" 2>/dev/null; then
    log "OK: crontab 已有 [$_kw]"
    return 0
  fi
  [ "$MODE" = "check" ] && { log "!! crontab 缺 [$_kw]（check 模式不改）"; return 0; }
  echo "$_line" >> "$CRON_FILE"
  crontab "$CRON_FILE" 2>/dev/null
  log "FIX: 已补回 crontab 行 [$_kw]"
}

# ---------------------------------------------------------------------------
section "1. 恢复本地补丁"
# PATCH_SPEC 每项形如  路径=标记1,标记2
for spec in $PATCH_SPEC; do
  _rel=${spec%%=*}
  _marks=${spec#*=}
  [ -n "$_rel" ] || continue
  _target="$CRASHDIR/$_rel"
  # 备份目录可以是「镜像目录结构」，也可以是「平铺」（只放文件名）
  if [ -f "$PATCH_DIR/$_rel" ]; then
    _backup="$PATCH_DIR/$_rel"
  else
    _backup="$PATCH_DIR/$(basename "$_rel")"
  fi
  if has_all_markers "$_target" "$_marks"; then
    log "OK: $_rel 已含标记 [$_marks]"
  elif [ -f "$_backup" ]; then
    if [ "$MODE" = "check" ]; then
      log "!! $_rel 缺标记 [$_marks]，但 $PATCH_DIR 有备份（check 模式不恢复）"
    else
      cp -f "$_target" "$_target.upstream.$TS" 2>/dev/null
      cp -f "$_backup" "$_target" 2>/dev/null
      chmod 755 "$_target" 2>/dev/null
      log "FIX: $_rel 已从 $PATCH_DIR 恢复（官方版另存为 .upstream.$TS）"
    fi
  else
    log "!! $_rel 缺标记 [$_marks] 且 $PATCH_DIR 没有备份"
  fi
done
for f in $(echo "$PATCH_SPEC" | tr ' ' '\n' | sed 's/=.*//' | grep -v '^$'); do
  [ -f "$CRASHDIR/$f" ] && { sh -n "$CRASHDIR/$f" 2>/dev/null && log "$f 语法 OK" || log "!! $f 语法错误"; }
done

# ---------------------------------------------------------------------------
section "2. 补回 cron 生命线"
ensure_cron "$(basename "${GUARDIAN_PATH:-guardian.sh}")" "$GUARDIAN_CRON_LINE"
ensure_cron "start_legacy_wd.sh" "$CRON_WD_LINE"
ensure_cron "task.sh 106" "$CRON_SAVE_LINE"

# ---------------------------------------------------------------------------
section "3. 启动链路兜底检查"
if grep -q "mkdir -p $RUNTIME_DIR" "$RC_LOCAL" 2>/dev/null; then
  log "OK: rc.local 建运行时目录在"
else
  log "!! rc.local 里没有 mkdir -p $RUNTIME_DIR（/tmp 是 tmpfs，目录缺失会让代理起不来）"
fi
if [ -n "$GUARDIAN_PATH" ] && [ -f "$GUARDIAN_PATH" ]; then
  grep -q "mkdir -p" "$GUARDIAN_PATH" 2>/dev/null && log "OK: guardian 建运行时目录在" || log "!! guardian.sh 缺 mkdir"
  grep -q "cron lifeline" "$GUARDIAN_PATH" 2>/dev/null && log "OK: guardian cron 自愈在" || log "!! guardian.sh 缺 cron lifeline"
fi
if [ "$WARN_INIT_ENABLED" = "1" ] && [ -x /etc/init.d/shellcrash ]; then
  if /etc/init.d/shellcrash enabled 2>/dev/null; then
    log "!! 警告：init.d/shellcrash 被启用了（legacy 模式会产生僵尸实例），建议 disable"
  else
    log "OK: init.d/shellcrash 保持 disabled"
  fi
fi

# ---------------------------------------------------------------------------
section "4. 启动"
mkdir -p "$RUNTIME_DIR"
core_up() {
  pidof "$CORE_PROC" >/dev/null 2>&1 && netstat -lntp 2>/dev/null | grep -q ":$MIXED_PORT"
}
if core_up; then
  log "已在运行，跳过启动"
elif [ "$MODE" = "check" ]; then
  log "!! 核心未运行（check 模式不启动）"
else
  sh "$CRASHDIR/start.sh" start 2>&1 | tail -25 | tee -a "$LOG"
  i=0
  while [ "$i" -lt 30 ]; do
    core_up && break
    sleep 1
    i=$((i + 1))
  done
  pidof "$CORE_PROC" >/dev/null 2>&1 && log "$CORE_PROC 已运行" || log "!! $CORE_PROC 未起来"
fi

# ---------------------------------------------------------------------------
section "5. 验收"
RCFG="$RUNTIME_DIR/config.yaml"
if [ -s "$RCFG" ]; then
  if [ -x "$CORE_BIN" ]; then
    "$CORE_BIN" -t -d "$CRASHDIR" -f "$RCFG" 2>&1 | tail -3 | tee -a "$LOG"
  fi
  log "分组数：$(grep -c '^  - name:' "$RCFG")"
  log "规则数：$(grep -c '^  - ' "$RCFG")"
  if [ -n "$CHECK_GROUP" ]; then
    grep -Fq "$CHECK_GROUP" "$RCFG" && log "自定义组 $CHECK_GROUP：OK" || log "!! 自定义组 $CHECK_GROUP 缺失"
  fi
else
  log "!! 运行态配置不存在"
fi
curl -s --max-time 8 -o /dev/null -w "direct=%{http_code} " "http://$DIRECT_TEST_HOST" 2>&1 | tee -a "$LOG"
curl -s --max-time 12 -x "http://127.0.0.1:$PROXY_PORT" -o /dev/null -w "proxy=%{http_code}\n" "$PROXY_TEST_URL" 2>&1 | tee -a "$LOG"

log ""
log "日志：$LOG"
exit 0
