#!/bin/sh
#
# setup-zram.sh —— 给低内存 OpenWrt 设备启用 zram 压缩 swap（幂等，可重复执行）
#
# 为什么：239MB 的 MT7981 设备上，mihomo 常驻 70MB+、内核不可回收 slab 27MB，
# 一旦瞬时峰值（PUT /configs 整份 reload 会让内存翻倍）超过余量，OOM killer 直接
# 杀掉核心，守护要等下一轮 cron 才拉起。zram 把匿名页压缩后放在 RAM 里，用 CPU
# 换内存 —— 压力先落到压缩换出，而不是内核直接杀进程。
#
# 硬约束（照 rc.local 的规矩）：
#   1. 每一步都幂等 —— 跑第二遍不改坏任何东西
#   2. 不改动 swap 已有内容，不动 ShellCrash / mihomo 任何配置
#   3. 只在真的缺包时才装（要联网），其余全部离线可跑
#
# 用法：
#   sh setup-zram.sh                 # 按默认值配置（RAM/2 大小，lzo-rle，swappiness=80）
#   sh setup-zram.sh --status        # 只报告当前 zram / swap / 内存状况，不改任何东西
#   sh setup-zram.sh --dry-run       # 打印将要执行的每一项，不落盘
#   sh setup-zram.sh --size-mb 64    # 指定 zram 大小（MB）
#   sh setup-zram.sh --algo zstd     # 指定压缩算法（lzo-rle / lzo / lz4 / zstd / deflate）
#   sh setup-zram.sh --swappiness 60 # 指定 vm.swappiness（默认 80）
#
set -u

PROG=setup-zram
SYSCTL_FILE=/etc/sysctl.d/99-zram.conf
INIT_SCRIPT=/etc/init.d/zram
ZRAM_DEV=/dev/zram0
SIZE_MB=""
ALGO="lzo-rle"
SWAPPINESS=80
MODE=apply

log() { logger -t "$PROG" "$*" 2>/dev/null; echo "[$PROG] $*"; }
die() { echo "[$PROG] !! $*" >&2; logger -t "$PROG" "!! $*" 2>/dev/null; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --status)     MODE=status ;;
    --dry-run)    MODE=dry ;;
    --size-mb)    shift; SIZE_MB="${1:-}" ;;
    --algo)       shift; ALGO="${1:-}" ;;
    --swappiness) shift; SWAPPINESS="${1:-}" ;;
    -h|--help)    sed -n '2,25p' "$0"; exit 0 ;;
    *)            die "未知参数：$1" ;;
  esac
  shift
done

mem_total_mb() {
  awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo
}
mem_avail_mb() {
  awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo
}

show_status() {
  echo "--- 内存 ---"
  free -m
  echo "--- swap ---"
  cat /proc/swaps 2>/dev/null || echo "(无 swap)"
  echo "--- zram 设备 ---"
  if [ -b "$ZRAM_DEV" ]; then
    echo "disksize:     $(cat /sys/block/zram0/disksize 2>/dev/null) 字节"
    echo "算法(可用):   $(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
    echo "mm_stat:      $(cat /sys/block/zram0/mm_stat 2>/dev/null)"
    echo "  ^ 字段顺序：orig_data_size compr_data_size mem_used_total mem_limit"
    echo "             mem_used_max same_pages pages_compacted huge_pages huge_pages_since"
  else
    echo "未创建（缺 kmod-zram 或未启动 init 脚本）"
  fi
  echo "--- 压缩算法配置（重启后生效） ---"
  echo "zram_comp_algo: $(uci -q get system.@system[0].zram_comp_algo || echo '(未设，用内核默认 lzo)')"
  echo "zram_size_mb:   $(uci -q get system.@system[0].zram_size_mb || echo '(未设，用 RAM/2)')"
  echo "--- 换出倾向 ---"
  echo "vm.swappiness:  $(cat /proc/sys/vm/swappiness)"
  echo "sysctl.d:       $SYSCTL_FILE $([ -f "$SYSCTL_FILE" ] && echo '(已存在)' || echo '(缺失)')"
  echo "--- 开机自启 ---"
  ls -l /etc/rc.d/ 2>/dev/null | grep -i zram || echo "rc.d 里没有 zram 链接（重启后不会自动启用）"
}

# ---------------------------------------------------------------------------
# --status：只读
# ---------------------------------------------------------------------------
if [ "$MODE" = status ]; then
  show_status
  exit 0
fi

DRY=0
[ "$MODE" = dry ] && DRY=1
run() {
  if [ "$DRY" = 1 ]; then echo "  [dry] $*"; else "$@"; fi
}

RAM_MB=$(mem_total_mb)
[ -n "$RAM_MB" ] || die "读不到 MemTotal"
[ -n "$SIZE_MB" ] || SIZE_MB=$((RAM_MB / 2))

echo "===== 目标：zram ${SIZE_MB}MB / 算法 $ALGO / swappiness $SWAPPINESS（物理内存 ${RAM_MB}MB） ====="

# ---------------------------------------------------------------------------
# 1. 装包（已有就跳过）
# ---------------------------------------------------------------------------
echo "--- 1. 内核模块与 init 脚本 ---"
if [ -b "$ZRAM_DEV" ] && [ -f "$INIT_SCRIPT" ]; then
  log "zram 已在位（$ZRAM_DEV + $INIT_SCRIPT），跳过装包"
else
  if command -v apk >/dev/null 2>&1; then
    # OpenWrt 25.x 起改用 apk；kmod-zram 必须与内核版本精确匹配，apk 会自动挑
    if apk info -e kmod-zram >/dev/null 2>&1; then
      log "kmod-zram 已安装"
    else
      log "apk add kmod-zram zram-swap"
      run apk update || log "apk update 失败（索引可能已有），继续尝试安装"
      run apk add kmod-zram zram-swap || die "apk add 失败：装不上 kmod-zram（内核版本与源不匹配？）"
    fi
  elif command -v opkg >/dev/null 2>&1; then
    if opkg list-installed 2>/dev/null | grep -q '^kmod-zram'; then
      log "kmod-zram 已安装"
    else
      log "opkg update && opkg install kmod-zram zram-swap"
      run opkg update
      run opkg install kmod-zram zram-swap || die "opkg install 失败"
    fi
  else
    die "既没有 apk 也没有 opkg，无法装包"
  fi
fi

# ---------------------------------------------------------------------------
# 2. 大小与压缩算法：写进 uci，重启后由 init 脚本读取
#    运行中的 swap 不能换算法（set failed），所以这里只落配置
# ---------------------------------------------------------------------------
echo "--- 2. 大小与压缩算法（uci，重启生效） ---"
run uci set "system.@system[0].zram_size_mb=$SIZE_MB"
run uci set "system.@system[0].zram_comp_algo=$ALGO"
run uci commit system

# ---------------------------------------------------------------------------
# 3. swappiness：zram 场景下调高 —— 换出到压缩内存比丢弃 page cache 划算
# ---------------------------------------------------------------------------
echo "--- 3. vm.swappiness ---"
if [ -f "$SYSCTL_FILE" ] && grep -q "^vm.swappiness" "$SYSCTL_FILE" 2>/dev/null; then
  log "$SYSCTL_FILE 已存在，不改写"
else
  if [ "$DRY" = 1 ]; then
    echo "  [dry] 写入 $SYSCTL_FILE: vm.swappiness = $SWAPPINESS"
  else
    mkdir -p /etc/sysctl.d
    cat > "$SYSCTL_FILE" <<EOF
# zram 压缩 swap 场景：鼓励换出匿名页到压缩内存，而不是丢弃 page cache
# 由 setup-zram.sh 生成；改完执行 sysctl -w vm.swappiness=<值> 立即生效
vm.swappiness = $SWAPPINESS
EOF
    log "已写 $SYSCTL_FILE"
  fi
fi
run sh -c "echo $SWAPPINESS > /proc/sys/vm/swappiness"

# ---------------------------------------------------------------------------
# 4. 唤醒：还没起就起，已起就不动（不 swapoff，避免把已换出的页全拉回内存）
# ---------------------------------------------------------------------------
echo "--- 4. 启用 ---"
if [ -b "$ZRAM_DEV" ] && grep -q "$ZRAM_DEV" /proc/swaps 2>/dev/null; then
  log "$ZRAM_DEV 已在 swap 中，保持现状（不 swapoff，避免拉回已换出的页）"
else
  if [ -x "$INIT_SCRIPT" ]; then
    run "$INIT_SCRIPT" enable
    run "$INIT_SCRIPT" start || die "启动 $INIT_SCRIPT 失败"
  else
    die "缺少 $INIT_SCRIPT（包没装成功？）"
  fi
fi

# ---------------------------------------------------------------------------
# 5. 验收
# ---------------------------------------------------------------------------
echo "--- 5. 结果 ---"
if [ "$DRY" = 1 ]; then
  echo "（dry-run 未做验收）"
  exit 0
fi
grep -q "$ZRAM_DEV" /proc/swaps || die "$ZRAM_DEV 未出现在 /proc/swaps"
ls /etc/rc.d/ 2>/dev/null | grep -qi 'zram' || log "!! rc.d 里没有 zram 自启链接，重启后需手动 start"
show_status
echo "===== 完成。重启后生效项：zram 大小 ${SIZE_MB}MB、算法 $ALGO ====="
exit 0
