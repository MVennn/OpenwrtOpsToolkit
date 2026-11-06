#!/bin/sh
# ============================================================================
# traffic-stats.sh —— 按「命中的策略组 + 域名」累计流量，回答「机场流量被谁吃了」
#
# 为什么需要它：nlbwmon 只能按 LAN 主机记账（PC / 手机 / 电视），而省流量的
# 决策要按「哪个站、走了哪个组」。mihomo 的 /connections 会给出每条连接的
# 域名、命中的策略组和累计字节，但不保存历史 —— 所以每分钟采样一次，只记增量。
#
# 资源账（实测见 OpenwrtOpsToolkit/CHANGELOG）：一次采样 = curl(10–40 KB) +
#   一个 sed + 一个 awk，峰值 RSS 约 4 MB，进程退出即释放；不常驻、不碰 conntrack。
#
# 增量怎么算（关键）：/connections 里的 upload/download 是**连接累计值**，
#   同一连接会在多次采样里重复出现。直接累加会重复计数，所以按连接 id 记住
#   「上次看到的字节」，每次只加差值；连接消失后该 id 从状态里自然淘汰。
#
# 输出：
#   /etc/ShellCrash/stats/YYYY-MM-DD.tsv   每行：策略组<TAB>域名<TAB>上行<TAB>下行
#     —— 差值先攒在 /tmp 的当日缓冲，每 STATS_FLUSH_MIN 分钟（默认 10）才
#     聚合落盘一次（闪存降频：旧版每分钟全量重写当日文件，一天最多 1440 次写；
#     攒批后一天 ≤144 次，文件格式与口径不变）。重启最多丢最后一个间隔内的
#     增量（缓冲在 tmpfs；对「大流量归因」无感，总量仍以 nlbwmon 为准）。
#   /tmp/ShellCrash/traffic-stats.state    连接 id → 上次字节（tmpfs，重启重建）
#
# 已知偏差：两次采样之间**开完就关**的短连接会被漏掉（列表里已没有它），
#   所以小请求偏低估；新出现的连接先记「种子」不计差值，从下一次采样起才计，
#   免得把连接建立以来的累计字节一次性计入（核心重启 / 状态丢失后不虚高）。
#   对「大流量归因」足够准。总量以 nlbwmon 为准。
#
# 配置：走 conf/device.conf（或同名环境变量）—— CRASHDIR / RUNTIME_DIR /
#   CTRL_HOST / CTRL_PORT / API_CFG；secret 运行时从 API_CFG 现读，脚本不存任何值。
#
# 用法：
#   sh traffic-stats.sh            # 采样一次（cron 每分钟）
#   sh traffic-stats.sh --report   # 打印按策略组 / 按域名的累计
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
_OPS_VARS="CRASHDIR RUNTIME_DIR CTRL_HOST CTRL_PORT API_CFG"
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
# RUNTIME_DIR 是 device.conf 里的正名（其余脚本都用它）；TMPDIR 兼容 ShellCrash 环境
TMPDIR="${RUNTIME_DIR:-${TMPDIR:-/tmp/ShellCrash}}"
CTRL_HOST="${CTRL_HOST:-127.0.0.1}"
CTRL_PORT="${CTRL_PORT:-9999}"
API_CFG="${API_CFG:-$CRASHDIR/configs/ShellCrash.cfg}"
STATS_DIR="$CRASHDIR/stats"
STATE="$TMPDIR/traffic-stats.state"
# 当日差值的落盘缓冲（tmpfs）：按日期分文件（traffic-stats.buf.YYYY-MM-DD），
# 攒到 STATS_FLUSH_MIN 分钟才聚合进 $STATS_DIR 的当日 tsv —— 闪存降频用。
BUF="$TMPDIR/traffic-stats.buf"
API="http://$CTRL_HOST:$CTRL_PORT/connections"

mkdir -p "$STATS_DIR" "$TMPDIR" 2>/dev/null
trap 'rm -f "$TMPDIR"/traffic-stats.*.$$ "$STATE.new" "$STATE.delta"' EXIT INT TERM HUP

# ---------------------------------------------------------------- 报表模式
if [ "$1" = "--report" ]; then
	for f in "$STATS_DIR"/*.tsv; do
		[ -f "$f" ] || continue
		echo "=== $(basename "$f" .tsv) —— 按策略组 ==="
		awk -F'\t' '{ u[$1]+=$3; d[$1]+=$4 } END {
			for (k in u) printf "%9.1f MB  ↑  %9.1f MB  ↓   %s\n", u[k]/1048576, d[k]/1048576, k
		}' "$f" | sort -rn | head -12
		echo "--- 按域名 top10 ---"
		awk -F'\t' '{ t[$2]+=$3+$4 } END {
			for (k in t) printf "%9.1f MB   %s\n", t[k]/1048576, k
		}' "$f" | sort -rn | head -10
		echo
	done
	exit 0
fi

# ------------------------------------------------------- 汇总模式（跨天）
# --summary：把 $STATS_DIR 下所有 tsv 合成一张账 —— 分账（机场出口 / 直连 / 兜底）
#   + 按组合计 + 域名 top20。回答「这段时间机场流量被谁吃了」。
#   组名改了就覆盖 STATS_AIRPORT_GROUPS / STATS_DIRECT_GROUPS（`|` 分隔的 ERE）。
if [ "$1" = "--summary" ]; then
	AG="${STATS_AIRPORT_GROUPS:-🚀 节点选择|🤖 干净出口|🤖 AI接口|🤖 人工智能|🔗 GitHub 出口|🎬 B站解锁|🎥 NETFLIX|𝕏 媒体|♻️ 自动选择}"
	DG="${STATS_DIRECT_GROUPS:-^DIRECT$|🎯 全球直连}"
	_n=$(ls "$STATS_DIR"/*.tsv 2>/dev/null | grep -c . 2>/dev/null)
	_f=$(ls "$STATS_DIR"/*.tsv 2>/dev/null | head -1)
	_l=$(ls "$STATS_DIR"/*.tsv 2>/dev/null | tail -1)
	_f=${_f##*/}; _f=${_f%.tsv}
	_l=${_l##*/}; _l=${_l%.tsv}
	echo "=== 汇总：${_n:-0} 个统计日（${_f:-?} ~ ${_l:-?}）==="
	cat "$STATS_DIR"/*.tsv 2>/dev/null | awk -F'\t' -v air="$AG" -v dir="$DG" '
	{ u = $3 + 0; d = $4 + 0; T += u + d
	  if ($1 ~ air)      A += u + d
	  else if ($1 ~ dir) D += u + d
	  else               O += u + d }
	END {
	  if (T == 0) { print "（没有数据）"; exit }
	  printf "总量        %9.1f MB\n", T / 1048576
	  printf "机场出口    %9.1f MB  %5.1f%%\n", A / 1048576, A * 100 / T
	  printf "直连        %9.1f MB  %5.1f%%\n", D / 1048576, D * 100 / T
	  printf "兜底/混合   %9.1f MB  %5.1f%%\n", O / 1048576, O * 100 / T
	}'
	echo "-- 按组合计 --"
	cat "$STATS_DIR"/*.tsv 2>/dev/null \
		| awk -F'\t' '{ t[$1] += $3 + $4 } END { for (k in t) printf "%d\t%s\n", t[k], k }' \
		| sort -rn | head -15 \
		| awk -F'\t' '{ printf "  %9.1f MB  %s\n", $1 / 1048576, $2 }'
	echo "-- 域名 top20 --"
	cat "$STATS_DIR"/*.tsv 2>/dev/null \
		| awk -F'\t' '{ t[$2] += $3 + $4 } END { for (k in t) printf "%d\t%s\n", t[k], k }' \
		| sort -rn | head -20 \
		| awk -F'\t' '{ printf "  %9.1f MB  %s\n", $1 / 1048576, $2 }'
	exit 0
fi

# ---------------------------------------------------------------- 采样
# secret 与 guardian.sh / bulk-guard.sh 同源：运行时从 ShellCrash.cfg 现读。
# 读不到时按无鉴权请求（核心没开鉴权时这本来就是对的；开了鉴权则本轮 401 无数据）。
secret=$(sed -n 's/^secret=//p' "$API_CFG" 2>/dev/null | head -1)
[ -n "$secret" ] || echo "traffic-stats: 未从 $API_CFG 读到 secret，按无鉴权请求（若核心开了鉴权，本轮采样为空）" >&2
sample="$TMPDIR/traffic-stats.sample.$$"
rows="$TMPDIR/traffic-stats.rows.$$"

if [ -n "$secret" ]; then
	curl -s --max-time 8 -H "Authorization: Bearer $secret" "$API" >"$sample" 2>/dev/null
else
	curl -s --max-time 8 "$API" >"$sample" 2>/dev/null
fi
grep -q '"connections"' "$sample" 2>/dev/null || exit 0

# 一条连接一个记录：按 `},{` 切开（busybox sed 不支持在替换里插换行，所以整段
# 交给 awk 处理，一次读入、内存里切分）。chains 取最后一项 = 命中的策略组/节点。
awk '
{ payload = payload $0 }
END {
	n = split(payload, rec, /\},\{/)
	for (i = 1; i <= n; i++) {
		s = rec[i]
		if (!match(s, /"id":"[^"]*"/)) continue
		id = substr(s, RSTART + 6, RLENGTH - 7)
		host = ""
		if (match(s, /"host":"[^"]*"/)) host = substr(s, RSTART + 8, RLENGTH - 9)
		if (host == "" && match(s, /"destinationIP":"[^"]*"/)) host = substr(s, RSTART + 17, RLENGTH - 18)
		up = 0
		if (match(s, /"upload":[0-9]+/)) up = substr(s, RSTART + 9, RLENGTH - 9) + 0
		dn = 0
		if (match(s, /"download":[0-9]+/)) dn = substr(s, RSTART + 11, RLENGTH - 11) + 0
		grp = ""
		if (match(s, /"chains":\[[^]]*\]/)) {
			a = substr(s, RSTART + 10, RLENGTH - 11)
			gsub(/"/, "", a)
			m = split(a, parts, ",")
			grp = parts[m]
		}
		printf "%s\t%s\t%s\t%d\t%d\n", id, (host == "" ? "unknown" : host), (grp == "" ? "unknown" : grp), up, dn
	}
}' "$sample" >"$rows" 2>/dev/null

# 增量：新样本 − 旧状态（按 id），差值先进 /tmp 缓冲，落盘间隔到了才合并进当日
# 文件，同时刷新状态。
# 状态文件首次运行不存在 —— 先创建成空文件；判别「哪个是旧状态」用 FILENAME
# 而不是 FNR==NR：旧状态为空时 FNR==NR 对两个文件都成立，会把新样本全当成
# 旧状态跳过（状态就永远建不出来）。
# 首见连接只记「种子」不产差值：/connections 的字节是连接累计值，若按
# 「新值 − 0」计，核心重启 / 状态丢失后会把连接建立以来的字节一次性计入。
[ -f "$STATE" ] || : >"$STATE"
awk -F'\t' -v OFS='\t' -v oldfile="$STATE" -v delta="$STATE.delta" -v newstate="$STATE.new" '
	FILENAME == oldfile { lup[$1] = $4; ldn[$1] = $5; next }	# 旧状态：id host grp up dn
	{
		id = $1; host = $2; grp = $3; up = $4 + 0; dn = $5 + 0
		if (id in lup) {				# 见过的连接才计差值；新连接先记种子
			du = up - (lup[id] + 0)
			dd = dn - (ldn[id] + 0)
			if (du < 0) du = 0			# 计数回绕 / id 复用，按 0 计
			if (dd < 0) dd = 0
			if (du + dd > 0) print grp, host, du, dd >delta
		}
		print id, host, grp, up, dn >newstate
	}' "$STATE" "$rows" 2>/dev/null

# 差值先追加进 /tmp 的当日缓冲（tmpfs，不磨闪存），到落盘间隔才聚合进当日
# tsv（见下方 FLUSH_MIN）。缓冲按日期分文件：差值记到采样当天，跨天落盘时
# 各归各的日期 —— 与旧版逐分钟按 date +%F 归档的口径一致。
NOW_TS=$(date +%s)
BUF_OK=1
if [ -s "$STATE.delta" ]; then
	cat "$STATE.delta" >>"$BUF.$(date +%Y-%m-%d)" 2>/dev/null || BUF_OK=0
	# 落盘节拍的锚点在首个差值进缓冲时起算（只写一次；flush 后由落盘段刷新）
	[ -f "$BUF.ts" ] || echo "$NOW_TS" >"$BUF.ts" 2>/dev/null
fi
# 状态在缓冲写成功后才推进：/tmp 写失败（tmpfs 满）时本轮差值不丢，
# 下一轮按旧状态重新算出同样的差值（与旧版 awk >delta 失败即中断等价）；
# 本轮没有差值时状态照常推进（连接集合每轮都可能变）。
[ "$BUF_OK" = "1" ] && [ -s "$STATE.new" ] && mv -f "$STATE.new" "$STATE"

# ---- 落盘：缓冲攒够 STATS_FLUSH_MIN 分钟才合并进 $STATS_DIR 的当日 tsv ----
# 闪存账：旧版只要有增量就每分钟全量重写当日文件（一天最多 1440 次读改写）；
# 攒批后一天 ≤144 次（默认 10 分钟一 flush），tsv 格式与聚合口径完全不变。
# 落盘节拍记在 $BUF.ts（tmpfs，上次 flush 的 epoch 秒）—— 不能拿缓冲文件的
# mtime 当锚点：它每分钟都被追加刷新，永远「刚写过」，就永远等不到间隔了。
# STATS_FLUSH_MIN=0 可退回逐分钟落盘（每轮必 flush，等同旧版行为）。
FLUSH_MIN="${STATS_FLUSH_MIN:-10}"
case "$FLUSH_MIN" in ''|*[!0-9]*) FLUSH_MIN=10 ;; esac
LM=0
if [ -f "$BUF.ts" ]; then
	LM=$(cat "$BUF.ts" 2>/dev/null)
	case "$LM" in ''|*[!0-9]*) LM=0 ;; esac
fi
[ "$LM" -gt 0 ] || LM=$NOW_TS	# 首轮（或重启后）从现在起算窗口
FLUSHED=0
for b in "$BUF".*; do
	[ -f "$b" ] || continue
	d=${b#"$BUF".}
	case "$d" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) continue ;; esac
	# 当日缓冲到间隔才落盘；非当日（跨天残留）本轮立即落盘，各归各的日期
	if [ "$d" = "$(date +%Y-%m-%d)" ] && [ $((NOW_TS - LM)) -lt $((FLUSH_MIN * 60)) ]; then
		continue
	fi
	today="$STATS_DIR/$d.tsv"
	if [ -f "$today" ]; then
		# 就地汇总（按「策略组 + 域名」求和），不追加原始行：汇总后每台
		# 设备每天只有一两百行、两三百 KB（tmp+mv 原子覆盖）。
		awk -F'\t' -v OFS='\t' -v oldfile="$today" '
			FILENAME == oldfile { u[$1 SUBSEP $2] += $3; d[$1 SUBSEP $2] += $4; next }
			{ u[$1 SUBSEP $2] += $3; d[$1 SUBSEP $2] += $4 }
			END {
				for (k in u) {
					split(k, p, SUBSEP)
					print p[1], p[2], u[k], d[k]
				}
			}' "$today" "$b" >"$today.new" && mv -f "$today.new" "$today"
	else
		# 当日首个 flush：直接聚合缓冲本身（不给「当日文件是原始行」留窗口，
		# 保持旧版「tsv 任何时刻都是聚合后的」这一形态）
		awk -F'\t' -v OFS='\t' '
			{ u[$1 SUBSEP $2] += $3; d[$1 SUBSEP $2] += $4 }
			END {
				for (k in u) {
					split(k, p, SUBSEP)
					print p[1], p[2], u[k], d[k]
				}
			}' "$b" >"$today.new" && mv -f "$today.new" "$today"
	fi
	rm -f "$b" 2>/dev/null
	FLUSHED=1
done
[ "$FLUSHED" = "1" ] && echo "$NOW_TS" >"$BUF.ts" 2>/dev/null

# 只留 31 天，避免 overlay 无限增长。
find "$STATS_DIR" -name '*.tsv' -mtime +31 -delete 2>/dev/null
# 旧版以 find 的 rc=0 收尾；这里显式 exit 0，保证非落盘轮（上面的 && 链为假）
# 也不会把 rc=1 泄漏给 cron。
exit 0
