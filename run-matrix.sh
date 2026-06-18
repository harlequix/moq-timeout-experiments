#!/usr/bin/env bash
# run-matrix.sh - run the full experiment matrix for the ANRW paper.
#
# Usage:
#   sudo ./run-matrix.sh --video /path/to/video.mp4 [--duration 30] [--repeats 3]
#   sudo ./run-matrix.sh --video ... --parallel 4   # requires netns-setup-parallel.sh 4
#   sudo ./run-matrix.sh --video ... --conditions severe,severe-light  # run only selected conditions
#
# Matrix dimensions:
#   Network conditions x (none + strategies x timeouts) x repeats
#
# "none" strategy always uses timeout=0 (fully reliable).
# Timeout strategies are crossed with all timeout values.
#
# --parallel N: run N experiments concurrently using slots 0..N-1.
# Each slot needs its own network namespace (see netns-setup-parallel.sh).

set -euo pipefail

VIDEO=""
DURATION=30
REPEATS=3
PARALLEL=0
BASE_OUTDIR="./results/matrix-$(date +%Y%m%d-%H%M%S)"
FILTER_CONDITIONS=""
QLOG="--qlog"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --video)      VIDEO="$2"; shift 2;;
        --duration)   DURATION="$2"; shift 2;;
        --repeats)    REPEATS="$2"; shift 2;;
        --parallel)   PARALLEL="$2"; shift 2;;
        --outdir)     BASE_OUTDIR="$2"; shift 2;;
        --conditions)      FILTER_CONDITIONS="$2"; shift 2;;
        --conditions-file) CONDITIONS_FILE="$2"; shift 2;;
        --qlog)            QLOG="--qlog"; shift;;
        *)            echo "Unknown arg: $1"; exit 1;;
    esac
done

if [[ -z "$VIDEO" ]]; then
    echo "Error: --video is required"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CONDITIONS_FILE="${CONDITIONS_FILE:-$SCRIPT_DIR/conditions.conf}"
if [[ ! -f "$CONDITIONS_FILE" ]]; then
    echo "Error: conditions file not found: $CONDITIONS_FILE"
    exit 1
fi
CONDITIONS=()
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    CONDITIONS+=("$line")
done < "$CONDITIONS_FILE"

if [[ -n "$FILTER_CONDITIONS" ]]; then
    FILTERED=()
    IFS=',' read -ra WANTED <<< "$FILTER_CONDITIONS"
    for cond_line in "${CONDITIONS[@]}"; do
        cond_name=$(echo "$cond_line" | awk '{print $1}')
        for w in "${WANTED[@]}"; do
            if [[ "$cond_name" == "$w" ]]; then
                FILTERED+=("$cond_line")
                break
            fi
        done
    done
    if [[ ${#FILTERED[@]} -eq 0 ]]; then
        echo "Error: --conditions '$FILTER_CONDITIONS' matched nothing"
        echo "Available: $(printf '%s\n' "${CONDITIONS[@]}" | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')"
        exit 1
    fi
    CONDITIONS=("${FILTERED[@]}")
fi

# Timeout strategies (excluding "none")
TIMEOUT_STRATEGIES=(
    "reset-stream"
    "reset-at-object"
    "reset-at-keyframe"
)

# Per-object delivery timeouts
TIMEOUTS=(
    "100ms"
    "200ms"
    "500ms"
    "1000ms"
)

combos_per_cond=$(( 1 + ${#TIMEOUT_STRATEGIES[@]} * ${#TIMEOUTS[@]} ))
total=$(( ${#CONDITIONS[@]} * combos_per_cond * REPEATS ))

REAL_USER="${SUDO_USER:-$(whoami)}"

mkdir -p "$BASE_OUTDIR"
chown "$REAL_USER":"$(id -gn "$REAL_USER")" "$BASE_OUTDIR"

cat > "$BASE_OUTDIR/matrix.json" <<EOF
{
    "video": "$VIDEO",
    "duration_s": $DURATION,
    "repeats": $REPEATS,
    "parallel": $PARALLEL,
    "conditions": $(printf '%s\n' "${CONDITIONS[@]}" | jq -R -s 'split("\n") | map(select(length > 0))'),
    "timeout_strategies": $(printf '%s\n' "${TIMEOUT_STRATEGIES[@]}" | jq -R -s 'split("\n") | map(select(length > 0))'),
    "timeouts": $(printf '%s\n' "${TIMEOUTS[@]}" | jq -R -s 'split("\n") | map(select(length > 0))'),
    "timestamp": "$(date -Iseconds)"
}
EOF

echo "=== MoQ Experiment Matrix ==="
echo "  Conditions:  ${#CONDITIONS[@]}"
echo "  Strategies:  none + ${#TIMEOUT_STRATEGIES[@]} x ${#TIMEOUTS[@]} timeouts"
echo "  Combos/cond: $combos_per_cond"
echo "  Repeats:     $REPEATS"
echo "  Total runs:  $total"
if [[ "$PARALLEL" -gt 0 ]]; then
    echo "  Parallel:    $PARALLEL slots"
    echo "  Est. time:   ~$((total * (DURATION + 20) / PARALLEL / 60))min"
else
    echo "  Parallel:    off (sequential)"
    echo "  Est. time:   ~$((total * (DURATION + 20) / 60))min"
fi
echo "  Output:      $BASE_OUTDIR"
echo ""

# Build job list (each job: cond_name delay loss bw strategy timeout)
JOBS=()
for cond_line in "${CONDITIONS[@]}"; do
    read -r cond_name delay loss bw <<< "$cond_line"
    JOBS+=("$cond_name $delay $loss $bw none 0")
    for strategy in "${TIMEOUT_STRATEGIES[@]}"; do
        for timeout in "${TIMEOUTS[@]}"; do
            JOBS+=("$cond_name $delay $loss $bw $strategy $timeout")
        done
    done
done

run_one() {
    local job_num="$1" cond_name="$2" delay="$3" loss="$4" bw="$5" strategy="$6" timeout="$7" rep="$8"
    local slot_arg=""
    if [[ -n "${9:-}" ]]; then
        slot_arg="--slot $9"
    fi

    local label="${strategy}"
    if [[ "$timeout" != "0" ]]; then
        label="${strategy}-${timeout}"
    fi
    local outdir="$BASE_OUTDIR/${cond_name}/${label}/run${rep}"
    mkdir -p "$outdir"

    echo "[$job_num/$total] $cond_name / $label / run $rep${9:+ (slot $9)}"

    "$SCRIPT_DIR/run-experiment.sh" \
        --video "$VIDEO" \
        --strategy "$strategy" \
        --timeout "$timeout" \
        --delay "$delay" \
        --loss "$loss" \
        --bandwidth "$bw" \
        --duration "$DURATION" \
        --outdir "$outdir" \
        --subscribers 1 \
        --fps 30 \
        $slot_arg \
        $QLOG \
        2>&1 | tee "$outdir/run.log" | grep -E "^(===|  )" || true
    echo ""
}

# Sequential mode (default): loop reps outermost so a transient event can't taint all reps of one config.
if [[ "$PARALLEL" -le 0 ]]; then
    run=0
    for rep in $(seq 1 "$REPEATS"); do
        for job_line in "${JOBS[@]}"; do
            read -r cond_name delay loss bw strategy timeout <<< "$job_line"
            run=$((run + 1))
            run_one "$run" "$cond_name" "$delay" "$loss" "$bw" "$strategy" "$timeout" "$rep"
        done
    done

    chown -R "$REAL_USER":"$(id -gn "$REAL_USER")" "$BASE_OUTDIR"
    echo "=== Matrix Complete ==="
    echo "Results: $BASE_OUTDIR"
    echo ""
    echo "Aggregate with: python3 aggregate-results.py $BASE_OUTDIR"
    exit 0
fi

# Parallel mode
for s in $(seq 0 $((PARALLEL - 1))); do
    if ! ip netns list | grep -q "moq-sub-${s}"; then
        echo "Error: namespace moq-sub-${s} not found. Run: sudo ./netns-setup-parallel.sh $PARALLEL"
        exit 1
    fi
done

QUEUE=()
run=0
for job_line in "${JOBS[@]}"; do
    read -r cond_name delay loss bw strategy timeout <<< "$job_line"
    for rep in $(seq 1 "$REPEATS"); do
        run=$((run + 1))
        QUEUE+=("$run $cond_name $delay $loss $bw $strategy $timeout $rep")
    done
done

SLOT_PIDS=()
next_slot() {
    while true; do
        for s in $(seq 0 $((PARALLEL - 1))); do
            if [[ -z "${SLOT_PIDS[$s]:-}" ]] || ! kill -0 "${SLOT_PIDS[$s]}" 2>/dev/null; then
                echo "$s"
                return
            fi
        done
        sleep 0.5
    done
}

for queue_entry in "${QUEUE[@]}"; do
    read -r job_num cond_name delay loss bw strategy timeout rep <<< "$queue_entry"
    slot=$(next_slot)
    run_one "$job_num" "$cond_name" "$delay" "$loss" "$bw" "$strategy" "$timeout" "$rep" "$slot" &
    SLOT_PIDS[$slot]=$!
done

wait

chown -R "$REAL_USER":"$(id -gn "$REAL_USER")" "$BASE_OUTDIR"
echo "=== Matrix Complete ==="
echo "Results: $BASE_OUTDIR"
echo ""
echo "Aggregate with: python3 aggregate-results.py $BASE_OUTDIR"
