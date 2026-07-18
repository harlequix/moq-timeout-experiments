#!/usr/bin/env bash
#
# MoQ experiment matrix runner. Blocks in the config each run as their own
# cross-product (conditions x strategies x timeouts x reps).
#
# Usage:
#   ./run-matrix.sh [config] [--block NAME] [--filter PATTERN] [--repeats N] [--dry-run] [--matrix-id ID]
#
# Existing run dirs are skipped, so a matrix can be resumed.
set -uo pipefail
cd "$(dirname "$0")"

CONFIG="docker-matrix.conf"
BLOCK_FILTER=""
FILTER=""
DRY_RUN=false
MATRIX_ID="matrix-$(date +%Y%m%d-%H%M%S)"
REPEATS_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --block)     BLOCK_FILTER="$2"; shift 2 ;;
        --filter)    FILTER="$2"; shift 2 ;;
        --repeats)   REPEATS_OVERRIDE="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --matrix-id) MATRIX_ID="$2"; shift 2 ;;
        -*) echo "Unknown arg: $1"; exit 1 ;;
        *) CONFIG="$1"; shift ;;
    esac
done

[ -f "$CONFIG" ] || { echo "config not found: $CONFIG"; exit 1; }

declare -A SHAPE_OF
declare -A B_CONDS B_STRATS B_TIMEOUTS B_REPS B_VIDEO B_DURATION
BLOCKS=()
VIDEO="testdata/test_10s.mp4"
DURATION=15
REPS=3
block=""

while read -r key rest; do
    case "$key" in
        ''|'#'*) ;;
        '['*']')
            block="${key#[}"; block="${block%]}"
            BLOCKS+=("$block") ;;
        condition)
            SHAPE_OF["${rest%%|*}"]="${rest#*|}" ;;
        conditions-file)
            cf="$rest"
            case "$cf" in /*) ;; *) cf="$(dirname "$CONFIG")/$cf" ;; esac
            [ -f "$cf" ] || { echo "conditions file not found: $cf"; exit 1; }
            # netns harness format: name delay loss% bandwidth
            while read -r cname cdelay closs cbw; do
                case "$cname" in ''|'#'*) continue ;; esac
                SHAPE_OF["$cname"]="$cbw $cdelay ${closs}%"
            done < "$cf" ;;
        conditions) B_CONDS[$block]="$rest" ;;
        strategies)
            if [ -n "$block" ]; then B_STRATS[$block]="$rest"; else echo "strategies outside block"; exit 1; fi ;;
        timeouts)   B_TIMEOUTS[$block]="$rest" ;;
        video)      if [ -n "$block" ]; then B_VIDEO[$block]="$rest"; else VIDEO="$rest"; fi ;;
        duration)   if [ -n "$block" ]; then B_DURATION[$block]="$rest"; else DURATION="$rest"; fi ;;
        reps)       if [ -n "$block" ]; then B_REPS[$block]="$rest"; else REPS="$rest"; fi ;;
        *) echo "unknown config key: $key"; exit 1 ;;
    esac
done < "$CONFIG"

[ ${#BLOCKS[@]} -gt 0 ] || { echo "no blocks in $CONFIG"; exit 1; }

MANIFEST="results/$MATRIX_ID.csv"
export DOCKER_UID="$(id -u)" DOCKER_GID="$(id -g)"

run_one() {
    local run_id="$1" shape="$2" strategy="$3" timeout="$4" cond="$5" rep="$6" video="$7" duration="$8" blk="$9"
    if [ -n "$FILTER" ] && [[ "$run_id" != *"$FILTER"* ]]; then
        return 0
    fi
    if [ -d "results/$run_id" ]; then
        echo "[skip] $run_id (exists)"
        return 0
    fi
    if $DRY_RUN; then
        echo "[dry ] $run_id (shape: ${shape:-unshaped})"
        return 0
    fi
    echo "[run ] $run_id"
    mkdir -p "results/$(dirname "$run_id")"
    STRATEGY="$strategy" TIMEOUT="$timeout" SHAPE="$shape" VIDEO="$video" DURATION="$duration" RUN_ID="$run_id" \
        docker compose run --rm experiment > "results/$run_id.stdout" 2>&1
    local rc=$?
    if [ ! -f "$MANIFEST" ]; then
        mkdir -p results
        echo "run_id,block,condition,shape,strategy,timeout,video,duration,rep,exit_code" > "$MANIFEST"
    fi
    echo "$run_id,$blk,$cond,\"$shape\",$strategy,$timeout,$video,$duration,$rep,$rc" >> "$MANIFEST"
    [ $rc -ne 0 ] && echo "[FAIL] $run_id (rc=$rc)"
    return 0
}

total=0
for blk in "${BLOCKS[@]}"; do
    if [ -n "$BLOCK_FILTER" ] && [ "$blk" != "$BLOCK_FILTER" ]; then
        continue
    fi
    conds="${B_CONDS[$blk]:?block $blk has no conditions}"
    strats="${B_STRATS[$blk]:?block $blk has no strategies}"
    touts="${B_TIMEOUTS[$blk]:?block $blk has no timeouts}"
    reps="${REPEATS_OVERRIDE:-${B_REPS[$blk]:-$REPS}}"
    video="${B_VIDEO[$blk]:-$VIDEO}"
    duration="${B_DURATION[$blk]:-$DURATION}"
    for cond in $conds; do
        [ -v "SHAPE_OF[$cond]" ] || { echo "unknown condition $cond in block $blk"; exit 1; }
        shape="${SHAPE_OF[$cond]}"
        for strategy in $strats; do
            for timeout in $touts; do
                for rep in $(seq 1 "$reps"); do
                    run_one "${MATRIX_ID}/${blk}/${cond}_${strategy}_${timeout}_rep${rep}" \
                        "$shape" "$strategy" "$timeout" "$cond" "$rep" "$video" "$duration" "$blk"
                    total=$((total+1))
                done
            done
        done
    done
done

echo ""
echo "matrix done: $total cells, manifest: $MANIFEST"
