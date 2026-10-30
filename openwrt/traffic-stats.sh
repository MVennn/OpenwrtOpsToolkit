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
#   /tmp/ShellCrash/traffic-stats.state    连接 id → 上次字节（tmpfs，重启重建）
#
# 已知偏差：两次采样之间**开完就关**的短连接会被漏掉（列表里已没有它），
#   所以小请求偏低估；对「大流量归因」足够准。总量以 nlbwmon 为准。
#
# 用法：
#   sh traffic-stats.sh            # 采样一次（cron 每分钟）
#   sh traffic-stats.sh --report   # 打印按策略组 / 按域名的累计
# ============================================================================

CRASHDIR="${CRASHDIR:-/etc/ShellCrash}"
TMPDIR="${TMPDIR:-/tmp/ShellCrash}"
STATS_DIR="$CRASHDIR/stats"
STATE="$TMPDIR/traffic-stats.state"
CFG="$TMPDIR/config.yaml"
API="http://127.0.0.1:9999/connections"

mkdir -p "$STATS_DIR" "$TMPDIR" 2>/dev/null
trap 'rm -f "$TMPDIR"/traffic-stats.*.$$ "$STATE.new" "$STATE.delta"' EXIT

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

# ---------------------------------------------------------------- 采样
secret=$(grep -E '^secret:' "$CFG" 2>/dev/null | head -1 | sed 's/secret: *//; s/"//g')
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

# 增量：新样本 − 旧状态（按 id），差值落当日文件，同时刷新状态。
# 状态文件首次运行不存在 —— 先创建成空文件；判别「哪个是旧状态」用 FILENAME
# 而不是 FNR==NR：旧状态为空时 FNR==NR 对两个文件都成立，会把新样本全当成
# 旧状态跳过（状态就永远建不出来）。
[ -f "$STATE" ] || : >"$STATE"
awk -F'\t' -v OFS='\t' -v oldfile="$STATE" -v delta="$STATE.delta" -v newstate="$STATE.new" '
	FILENAME == oldfile { lup[$1] = $4; ldn[$1] = $5; next }	# 旧状态：id host grp up dn
	{
		id = $1; host = $2; grp = $3; up = $4 + 0; dn = $5 + 0
		du = up - (lup[id] + 0)
		dd = dn - (ldn[id] + 0)
		if (du < 0) du = 0				# 计数回绕 / id 复用，按 0 计
		if (dd < 0) dd = 0
		if (du + dd > 0) print grp, host, du, dd >delta
		print id, host, grp, up, dn >newstate
	}' "$STATE" "$rows" 2>/dev/null

[ -s "$STATE.delta" ] && {
	# 就地汇总进当日文件（按「策略组 + 域名」求和），不追加原始行：
	# 每分钟 10–30 行、一天 1440 次会把 overlay 撑到几十 MB，
	# 汇总后每台设备每天只有一两百行、两三百 KB。
	today="$STATS_DIR/$(date +%Y-%m-%d).tsv"
	if [ -f "$today" ]; then
		awk -F'\t' -v OFS='\t' -v oldfile="$today" '
			FILENAME == oldfile { u[$1 SUBSEP $2] += $3; d[$1 SUBSEP $2] += $4; next }
			{ u[$1 SUBSEP $2] += $3; d[$1 SUBSEP $2] += $4 }
			END {
				for (k in u) {
					split(k, p, SUBSEP)
					print p[1], p[2], u[k], d[k]
				}
			}' "$today" "$STATE.delta" >"$today.new" && mv -f "$today.new" "$today"
	else
		mv -f "$STATE.delta" "$today"
	fi
}
[ -s "$STATE.new" ] && mv -f "$STATE.new" "$STATE"

# 只留 31 天，避免 overlay 无限增长。
find "$STATS_DIR" -name '*.tsv' -mtime +31 -delete 2>/dev/null
