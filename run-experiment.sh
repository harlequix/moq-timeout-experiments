#!/usr/bin/env bash
# run-experiment.sh — Run a single MoQ timeout experiment.
#
# Prerequisites:
#   1. sudo ./netns-setup.sh  (creates network namespace)
#   2. Build binaries: (cd ../testbed && go build -o ../experiment/ ./cmd/...)
#      or run from testbed dir
#   3. Video file (H.264) exists
#
# Usage:
#   sudo ./run-experiment.sh \
#     --video /path/to/video.mp4 \
#     --strategy reset-at-keyframe \
#     --timeout 200ms \
#     --delay 40ms \
#     --loss 2 \
#     --bandwidth 10mbit \
#     --duration 30 \
#     --outdir ./results/exp001 \
#     --subscribers 2
#
# The script:
#   1. Configures netem on the veth inside the namespace
#   2. Starts publisher on host (localhost:4443)
#   3. Starts relay on host (upstream=localhost:4443, downstream=10.0.0.1:4444)
#   4. Starts N subscribers inside the namespace
#   5. Waits for duration, then collects results

set -euo pipefail

# --- Defaults ---
VIDEO=""
STRATEGY="none"
TIMEOUT="0"
DELAY="0ms"
LOSS="0"
BANDWIDTH=""
DURATION=30
OUTDIR="./results/$(date +%Y%m%d-%H%M%S)"
NUM_SUBS=1
NAMESPACE="live"
TRACK="video"
SLOT=""
PUB_PORT=4443
RELAY_PORT=4444
DEBUG=""
GOP_SIZE=""
NULL_SINK=""
EMBED_PTS=""
FPS=""
CONTAINER=""
QLOG=""

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --video)     VIDEO="$2"; shift 2;;
        --strategy)  STRATEGY="$2"; shift 2;;
        --timeout)   TIMEOUT="$2"; shift 2;;
        --delay)     DELAY="$2"; shift 2;;
        --loss)      LOSS="$2"; shift 2;;
        --bandwidth) BANDWIDTH="$2"; shift 2;;
        --duration)  DURATION="$2"; shift 2;;
        --outdir)    OUTDIR="$2"; shift 2;;
        --subscribers) NUM_SUBS="$2"; shift 2;;
        --namespace) NAMESPACE="$2"; shift 2;;
        --track)     TRACK="$2"; shift 2;;
        --gop)       GOP_SIZE="$2"; shift 2;;
        --slot)      SLOT="$2"; shift 2;;
        --null-sink) NULL_SINK="--null-sink"; shift;;
        --embed-pts) EMBED_PTS="--embed-pts"; shift;;
        --fps)       FPS="$2"; shift 2;;
        --container) CONTAINER="$2"; shift 2;;
        --qlog)      QLOG="--qlog-dir"; shift;;
        --debug)     DEBUG="--debug"; shift;;
        *)           echo "Unknown arg: $1"; exit 1;;
    esac
done

if [[ -z "$VIDEO" ]]; then
    echo "Error: --video is required"
    exit 1
fi

# --- Resolve slot to namespace/veth/IP/port ---
if [[ -n "$SLOT" ]]; then
    NS="moq-sub-${SLOT}"
    VETH_HOST="veth-host-${SLOT}"
    HOST_IP="10.0.${SLOT}.1"
    PUB_PORT=$((4443 + SLOT * 10))
    RELAY_PORT=$((4444 + SLOT * 10))
else
    NS="moq-sub"
    VETH_HOST="veth-host"
    HOST_IP="10.0.0.1"
fi

# Resolve binary paths — build into experiment dir if missing or stale
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTBED_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

build_bin() {
    local cmd="$1"
    local out="$SCRIPT_DIR/$cmd"
    # Rebuild if binary missing or any .go source is newer
    local newest_src
    newest_src=$(find "$TESTBED_DIR" -name '*.go' -newer "$out" 2>/dev/null | head -1)
    if [[ ! -x "$out" || -n "$newest_src" ]]; then
        echo "Building $cmd..." >&2
        (cd "$TESTBED_DIR" && go build -o "$out" "./cmd/$cmd/") || { echo "Build failed: $cmd" >&2; exit 1; }
    fi
    echo "$out"
}

PUB_BIN=$(build_bin "publisher")
RELAY_BIN=$(build_bin "relay")
SUB_BIN=$(build_bin "subscriber")

# Get the actual user (since we're running under sudo)
REAL_USER="${SUDO_USER:-$(whoami)}"

# --- Setup output directory ---
mkdir -p "$OUTDIR"
chown "$REAL_USER":"$(id -gn "$REAL_USER")" "$OUTDIR"

# Probe video metadata
VIDEO_RES=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$VIDEO")
VIDEO_BITRATE=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 "$VIDEO")
VIDEO_CODEC=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_name,profile -of csv=p=0 "$VIDEO")
VIDEO_FPS=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$VIDEO")
VIDEO_FRAMES=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 "$VIDEO")

# Write experiment metadata
cat > "$OUTDIR/experiment.json" <<METADATA
{
    "video": "$VIDEO",
    "video_resolution": "$VIDEO_RES",
    "video_bitrate_bps": ${VIDEO_BITRATE:-0},
    "video_codec": "$VIDEO_CODEC",
    "video_fps": "$VIDEO_FPS",
    "video_frames": ${VIDEO_FRAMES:-0},
    "strategy": "$STRATEGY",
    "timeout": "$TIMEOUT",
    "delay": "$DELAY",
    "loss_pct": $LOSS,
    "loss_model": "uniform",
    "delay_direction": "one-way",
    "bandwidth": "${BANDWIDTH:-unlimited}",
    "bandwidth_shaper": "htb",
    "duration_s": $DURATION,
    "num_subscribers": $NUM_SUBS,
    "gop_size": "${GOP_SIZE:-auto}",
    "cc_algorithm": "cubic",
    "timestamp": "$(date -Iseconds)"
}
METADATA

echo "=== MoQ Timeout Experiment ==="
echo "  Strategy:    $STRATEGY"
echo "  Timeout:     $TIMEOUT"
echo "  Delay:       $DELAY"
echo "  Loss:        ${LOSS}%"
echo "  Bandwidth:   ${BANDWIDTH:-unlimited}"
echo "  Duration:    ${DURATION}s"
echo "  Subscribers: $NUM_SUBS"
echo "  Binaries:    pub=$(basename "$PUB_BIN") relay=$(basename "$RELAY_BIN") sub=$(basename "$SUB_BIN")"
echo "  Bin dir:     $(dirname "$PUB_BIN")"
echo "  Output:      $OUTDIR"
echo ""

# --- Configure netem on veth-host (data path: relay → subscriber) ---
# Remove existing qdisc first (ignore errors)
tc qdisc del dev "$VETH_HOST" root 2>/dev/null || true

NETEM_ARGS="delay $DELAY"
if [[ "$LOSS" != "0" ]]; then
    NETEM_ARGS="$NETEM_ARGS loss ${LOSS}%"
fi

if [[ -n "$BANDWIDTH" && "$BANDWIDTH" != "unlimited" ]]; then
    # Use HTB for rate limiting + netem for delay/loss
    tc qdisc add dev "$VETH_HOST" root handle 1: htb default 10
    tc class add dev "$VETH_HOST" parent 1: classid 1:10 htb rate "$BANDWIDTH"
    tc qdisc add dev "$VETH_HOST" parent 1:10 handle 10: netem $NETEM_ARGS
else
    tc qdisc add dev "$VETH_HOST" root netem $NETEM_ARGS
fi

echo "netem configured: $NETEM_ARGS ${BANDWIDTH:+rate $BANDWIDTH}"

# --- Connectivity check (retry up to 5 times; tc qdisc replacement can cause transient failures) ---
echo "Checking namespace connectivity..."
PING_OK=0
for attempt in 1 2 3 4 5; do
    if ip netns exec "$NS" ping -c 1 -W 2 "$HOST_IP" >/dev/null 2>&1; then
        PING_OK=1
        break
    fi
    echo "  ping attempt $attempt failed, retrying..."
    sleep 1
done
if [[ "$PING_OK" -eq 0 ]]; then
    echo "ERROR: namespace '$NS' cannot reach $HOST_IP after 5 attempts"
    echo "  - Check namespace setup: sudo ./netns-setup.sh"
    exit 1
fi
# UDP check: send a single datagram to the relay port and verify it isn't rejected.
# Start a short-lived UDP listener, send a packet from the namespace, check arrival.
UDP_OK=0
timeout 2 bash -c "exec 3<>/dev/udp/$HOST_IP/$RELAY_PORT" 2>/dev/null && UDP_OK=1 || true
if [[ "$UDP_OK" -eq 0 ]]; then
    # More reliable: use socat/nc to actually test from inside the namespace
    if command -v socat >/dev/null 2>&1; then
        socat -u UDP-LISTEN:$RELAY_PORT,reuseaddr STDOUT &
        PROBE_PID=$!
        sleep 0.2
        ip netns exec "$NS" bash -c "echo probe | socat - UDP:$HOST_IP:$RELAY_PORT" 2>/dev/null && UDP_OK=1 || true
        kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null || true
    fi
fi
if [[ "$UDP_OK" -eq 0 ]]; then
    echo "ERROR: UDP traffic from namespace '$NS' to $HOST_IP:$RELAY_PORT is blocked"
    echo "  Likely cause: firewalld blocking UDP on the veth interface"
    echo "  Quick fix: sudo firewall-cmd --zone=trusted --add-interface=$VETH_HOST"
    exit 1
fi
echo "Connectivity OK: $NS -> $HOST_IP (ICMP + UDP)"

# --- Cleanup function ---
PIDS=()
cleanup() {
    echo ""
    echo "Shutting down..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    # Wait for graceful shutdown (relay needs time to drain forward loops and write metrics)
    sleep 5
    for pid in "${PIDS[@]}"; do
        kill -9 "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    # Fix output file ownership
    chown -R "$REAL_USER":"$(id -gn "$REAL_USER")" "$OUTDIR" 2>/dev/null || true
    echo "Results in: $OUTDIR"
}
trap cleanup EXIT

# --- Helper: wait for a log message (up to 10s) ---
wait_for_log() {
    local logfile="$1" pattern="$2" label="$3"
    for attempt in $(seq 1 100); do
        if grep -q "$pattern" "$logfile" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    echo "WARNING: timed out waiting for $label" >&2
    return 1
}

# --- Start publisher (listens, ffmpeg starts on first SUBSCRIBE) ---
echo "Starting publisher..."
sudo -u "$REAL_USER" "$PUB_BIN" \
    --listen "127.0.0.1:$PUB_PORT" \
    --video "$VIDEO" \
    --namespace "$NAMESPACE" \
    --track "$TRACK" \
    --manifest "$OUTDIR/manifest.csv" \
    --realtime \
    $EMBED_PTS \
    $DEBUG \
    > "$OUTDIR/publisher.log" 2>&1 &
PIDS+=($!)
wait_for_log "$OUTDIR/publisher.log" "publisher listening" "publisher ready" || true

# --- Start relay (listens immediately, connects upstream on first SUBSCRIBE) ---
echo "Starting relay..."
QLOG_ARGS=""
if [[ -n "$QLOG" ]]; then
    QLOG_ARGS="--qlog-dir $OUTDIR/qlog"
fi
sudo -u "$REAL_USER" "$RELAY_BIN" \
    --listen "$HOST_IP:$RELAY_PORT" \
    --upstream "127.0.0.1:$PUB_PORT" \
    --namespace "$NAMESPACE" \
    --track "$TRACK" \
    --strategy "$STRATEGY" \
    --default-timeout "$TIMEOUT" \
    --metrics "$OUTDIR/relay_metrics.csv" \
    $QLOG_ARGS \
    $DEBUG \
    > "$OUTDIR/relay.log" 2>&1 &
PIDS+=($!)
wait_for_log "$OUTDIR/relay.log" "listening for subscribers" "relay ready" || true

# --- Start subscribers (triggers: sub->relay->publisher->ffmpeg) ---
for i in $(seq 1 "$NUM_SUBS"); do
    echo "Starting subscriber $i..."
    SUB_EXTRA=""
    if [[ -n "$EMBED_PTS" ]]; then
        SUB_EXTRA="--embedded-pts"
    fi
    if [[ -n "$FPS" ]]; then
        SUB_EXTRA="$SUB_EXTRA --fps $FPS"
    fi
    if [[ -n "$CONTAINER" ]]; then
        SUB_EXTRA="$SUB_EXTRA --container $CONTAINER"
    fi
    ip netns exec "$NS" sudo -u "$REAL_USER" "$SUB_BIN" \
        --relay "$HOST_IP:$RELAY_PORT" \
        --namespace "$NAMESPACE" \
        --track "$TRACK" \
        --recv-log "$OUTDIR/sub${i}_recv.csv" \
        --display-log "$OUTDIR/sub${i}_display.csv" \
        $NULL_SINK \
        $SUB_EXTRA \
        $DEBUG \
        > "$OUTDIR/sub${i}.log" 2>&1 &
    PIDS+=($!)
done
wait_for_log "$OUTDIR/sub1.log" "subscribed" "subscriber ready" || true

GRACE=15
TOTAL_WAIT=$((DURATION + GRACE))
echo ""
echo "All components running. Waiting ${TOTAL_WAIT}s (${DURATION}s video + ${GRACE}s grace)..."
sleep "$TOTAL_WAIT"

echo ""
echo "=== Results ==="
echo ""

# Print summary
for i in $(seq 1 "$NUM_SUBS"); do
    recv="$OUTDIR/sub${i}_recv.csv"
    if [[ -f "$recv" ]]; then
        rows=$(tail -n +2 "$recv" | wc -l)
        echo "  Subscriber $i: $rows objects received"
    else
        echo "  Subscriber $i: no recv log"
    fi
done

# Relay in/out summary
relay_in=""
relay_drops=""
if [[ -f "$OUTDIR/relay.log" ]]; then
    relay_in=$(grep -oP 'ingested=\K[0-9]+' "$OUTDIR/relay.log" | tail -1)
    relay_drops=$(grep -oP 'chan_drops=\K[0-9]+' "$OUTDIR/relay.log" | tail -1)
fi
relay_out=""
if [[ -f "$OUTDIR/relay_metrics.csv" ]]; then
    relay_out=$(awk -F, 'NR>1 {sum+=$4} END {print sum+0}' "$OUTDIR/relay_metrics.csv")
fi

pub_rows=""
if [[ -f "$OUTDIR/manifest.csv" ]]; then
    pub_rows=$(tail -n +2 "$OUTDIR/manifest.csv" | wc -l | tr -d ' ')
fi

echo "  Pipeline: pub=${pub_rows:-?} → relay_in=${relay_in:-?} → relay_out=${relay_out:-?} → sub (chan_drops=${relay_drops:-?})"
