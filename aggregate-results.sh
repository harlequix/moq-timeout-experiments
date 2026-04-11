#!/usr/bin/env bash
# aggregate-results.sh — Collect experiment results into CSVs for analysis.
#
# Usage: ./aggregate-results.sh results/matrix-YYYYMMDD-HHMMSS
#
# Produces:
#   summary.csv        — one row per run (delivery counts, relay metrics)
#   latency.csv        — one row per received object (end-to-end latency)
#   summary_table.txt  — human-readable pivot table

set -euo pipefail

BASEDIR="${1:?Usage: $0 <results-dir>}"
SUMMARY="$BASEDIR/summary.csv"
LATENCY="$BASEDIR/latency.csv"

# --- summary.csv ---
echo "condition,strategy,timeout_ms,run,pub_total,pub_i,pub_p,recv_total,recv_i,recv_p,objects_dropped,groups_reset,groups_complete,delivery_ratio" > "$SUMMARY"

for expdir in "$BASEDIR"/*/*/run*; do
    [[ -d "$expdir" ]] || continue

    run_name=$(basename "$expdir")
    dir_strategy=$(basename "$(dirname "$expdir")")
    condition=$(basename "$(dirname "$(dirname "$expdir")")")
    run_num="${run_name#run}"

    manifest="$expdir/manifest.csv"
    recv="$expdir/sub1_recv.csv"
    metrics="$expdir/relay_metrics.csv"

    # Relay metrics (read first — strategy/timeout come from here)
    strategy="$dir_strategy"; timeout_ms=0
    dropped=0; groups_reset=0; groups_complete=0
    if [[ -f "$metrics" ]]; then
        line=$(tail -n 1 "$metrics")
        IFS=',' read -r _sid strategy timeout_ms _sent dropped groups_reset groups_complete <<< "$line"
    fi

    # Published I/P counts
    pub_total=0; pub_i=0; pub_p=0
    if [[ -f "$manifest" ]]; then
        read -r pub_i pub_p <<< "$(awk -F, 'NR>1 { if ($6=="I") i++; else p++ } END { print i+0, p+0 }' "$manifest")"
        pub_total=$((pub_i + pub_p))
    fi

    # Received I/P counts (object_id==0 is I-frame)
    recv_total=0; recv_i=0; recv_p=0
    if [[ -f "$recv" ]]; then
        read -r recv_i recv_p <<< "$(awk -F, 'NR>1 { if ($3==0) i++; else p++ } END { print i+0, p+0 }' "$recv")"
        recv_total=$((recv_i + recv_p))
    fi

    ratio=0.0000
    if [[ "$pub_total" -gt 0 ]]; then
        ratio=$(awk "BEGIN {printf \"%.4f\", $recv_total / $pub_total}")
    fi

    echo "$condition,$strategy,$timeout_ms,$run_num,$pub_total,$pub_i,$pub_p,$recv_total,$recv_i,$recv_p,$dropped,$groups_reset,$groups_complete,$ratio" >> "$SUMMARY"
done

# Sort
(head -1 "$SUMMARY" && tail -n +2 "$SUMMARY" | sort -t, -k1,1 -k2,2 -k4,4n) > "$SUMMARY.tmp"
mv "$SUMMARY.tmp" "$SUMMARY"

# --- latency.csv ---
echo "condition,strategy,timeout_ms,run,group_id,object_id,frame_type,latency_ms" > "$LATENCY"

for expdir in "$BASEDIR"/*/*/run*; do
    [[ -d "$expdir" ]] || continue

    run_name=$(basename "$expdir")
    dir_strategy=$(basename "$(dirname "$expdir")")
    condition=$(basename "$(dirname "$(dirname "$expdir")")")
    run_num="${run_name#run}"

    manifest="$expdir/manifest.csv"
    recv="$expdir/sub1_recv.csv"
    metrics="$expdir/relay_metrics.csv"
    [[ -f "$manifest" && -f "$recv" ]] || continue

    # Read strategy/timeout from relay metrics
    strategy="$dir_strategy"; timeout_ms=0
    if [[ -f "$metrics" ]]; then
        line=$(tail -n 1 "$metrics")
        IFS=',' read -r _sid strategy timeout_ms _ _ _ _ <<< "$line"
    fi

    # Join manifest (publish_ts_ns) with recv (receive_ts_ns) on (group_id, object_id)
    awk -F, -v cond="$condition" -v strat="$strategy" -v tms="$timeout_ms" -v run="$run_num" '
        NR==FNR && FNR>1 {
            key = $2 "," $3
            pub_ts[key] = $5
            ftype[key] = $6
            next
        }
        FNR>1 {
            key = $2 "," $3
            if (key in pub_ts) {
                lat_ms = ($4 - pub_ts[key]) / 1e6
                printf "%s,%s,%s,%s,%s,%s,%s,%.1f\n", cond, strat, tms, run, $2, $3, ftype[key], lat_ms
            }
        }
    ' "$manifest" "$recv" >> "$LATENCY"
done

summary_rows=$(tail -n +2 "$SUMMARY" | wc -l | tr -d ' ')
latency_rows=$(tail -n +2 "$LATENCY" | wc -l | tr -d ' ')
echo "Wrote $summary_rows runs to $SUMMARY"
echo "Wrote $latency_rows latency samples to $LATENCY"
echo ""

# --- Human-readable pivot table ---
TABLE="$BASEDIR/summary_table.txt"
{
echo "=== Delivery Summary (averaged across runs) ==="
echo ""
printf "%-12s %-20s %6s %4s | %5s %5s %5s | %5s %5s %5s | %5s %5s | %6s\n" \
    "CONDITION" "STRATEGY" "TMO" "RUNS" "PUB" "PUB_I" "PUB_P" "RECV" "RCV_I" "RCV_P" "RESET" "DROP" "RATIO"
printf "%-12s %-20s %6s-%4s-+-%5s-%5s-%5s-+-%5s-%5s-%5s-+-%5s-%5s-+-%6s\n" \
    "------------" "--------------------" "------" "----" "-----" "-----" "-----" "-----" "-----" "-----" "-----" "-----" "------"

tail -n +2 "$SUMMARY" | awk -F, '
{
    key = $1 "," $2 "," $3
    n[key]++
    pub[key]+=$5; pub_i[key]+=$6; pub_p[key]+=$7
    recv[key]+=$8; recv_i[key]+=$9; recv_p[key]+=$10
    drop[key]+=$11; reset[key]+=$12
    ratio[key]+=$14
}
END {
    for (key in n) {
        c = n[key]
        split(key, p, ",")
        tmo = (p[3]+0 == 0) ? "-" : p[3] "ms"
        printf "%-12s %-20s %6s %4d | %5.0f %5.0f %5.0f | %5.0f %5.0f %5.0f | %5.1f %5.0f | %6.3f\n",
            p[1], p[2], tmo, c,
            pub[key]/c, pub_i[key]/c, pub_p[key]/c,
            recv[key]/c, recv_i[key]/c, recv_p[key]/c,
            reset[key]/c, drop[key]/c, ratio[key]/c
    }
}' | sort

echo ""
echo "=== I-frame Latency Summary (ms) ==="
echo ""
printf "%-12s %-20s %6s %5s %7s %7s %7s %7s\n" "CONDITION" "STRATEGY" "TMO" "COUNT" "AVG" "P50" "P95" "MAX"
printf "%-12s %-20s %6s %5s %7s %7s %7s %7s\n" "------------" "--------------------" "------" "-----" "-------" "-------" "-------" "-------"

# I-frame latency: frame_type == I (column 7 in new format)
awk -F, 'NR>1 && $7=="I" { print $1 "," $2 "," $3, $8 }' "$LATENCY" | sort -t' ' -k1,1 | awk '
{
    key = $1; val = $2
    n[key]++
    sum[key] += val
    vals[key][n[key]] = val
}
END {
    for (key in n) {
        c = n[key]
        # Sort values for percentiles
        for (i=1; i<=c; i++)
            for (j=i+1; j<=c; j++)
                if (vals[key][i] > vals[key][j]) {
                    t = vals[key][i]; vals[key][i] = vals[key][j]; vals[key][j] = t
                }
        split(key, p, ",")
        tmo = (p[3]+0 == 0) ? "-" : p[3] "ms"
        p50 = vals[key][int(c*0.5)]
        p95 = vals[key][int(c*0.95)]
        mx  = vals[key][c]
        printf "%-12s %-20s %6s %5d %7.0f %7.0f %7.0f %7.0f\n",
            p[1], p[2], tmo, c, sum[key]/c, p50, p95, mx
    }
}' | sort

} > "$TABLE"

cat "$TABLE"
