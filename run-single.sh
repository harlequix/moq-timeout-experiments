#!/usr/bin/env bash
# run-single.sh — Run a single MoQ experiment with netem.
# Requires: netns-setup.sh already run, sudoers configured.
#
# Usage:
#   ./run-single.sh <strategy> <timeout> <delay> <loss%> <bandwidth> <duration> <outdir> <video>
set -euo pipefail

STRATEGY="${1:?usage: $0 strategy timeout delay loss bw duration outdir video [realtime]}"
TIMEOUT="${2:?}"
DELAY="${3:?}"
LOSS="${4:?}"
BW="${5:?}"
DURATION="${6:?}"
OUTDIR="${7:?}"
VIDEO="${8:?}"
REALTIME="${9:-false}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NS="moq-sub"
HOST_IP="10.0.0.1"
PUB_PORT=4443
RELAY_PORT=4444
PIDS=()

cleanup() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    sleep 2
    for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$OUTDIR"

# Configure netem on veth-host (data path: relay → subscriber)
sudo /usr/sbin/tc qdisc del dev veth-host root 2>/dev/null || true
if [[ "$BW" != "0" && "$BW" != "unlimited" ]]; then
    sudo /usr/sbin/tc qdisc add dev veth-host root handle 1: htb default 10
    sudo /usr/sbin/tc class add dev veth-host parent 1: classid 1:10 htb rate "$BW"
    sudo /usr/sbin/tc qdisc add dev veth-host parent 1:10 handle 10: netem delay "$DELAY" loss "${LOSS}%"
else
    sudo /usr/sbin/tc qdisc add dev veth-host root netem delay "$DELAY" loss "${LOSS}%"
fi

# Start publisher
"$SCRIPT_DIR/moq-publisher" \
    --listen "127.0.0.1:$PUB_PORT" \
    --video "$VIDEO" \
    --namespace live --track video \
    --manifest "$OUTDIR/manifest.csv" \
    --realtime="$REALTIME" \
    >"$OUTDIR/publisher.log" 2>&1 &
PIDS+=($!)
sleep 2

# Start relay
"$SCRIPT_DIR/moq-relay" \
    --listen "$HOST_IP:$RELAY_PORT" \
    --upstream "127.0.0.1:$PUB_PORT" \
    --namespace live --track video \
    --strategy "$STRATEGY" \
    --default-timeout "$TIMEOUT" \
    --metrics "$OUTDIR/relay_metrics.csv" \
    >"$OUTDIR/relay.log" 2>&1 &
PIDS+=($!)
sleep 2

# Start subscriber in namespace
sudo ip netns exec "$NS" sudo -u "$(whoami)" "$SCRIPT_DIR/moq-subscriber" \
    --relay "$HOST_IP:$RELAY_PORT" \
    --namespace live --track video \
    --recv-log "$OUTDIR/sub1_recv.csv" \
    --display-log "$OUTDIR/sub1_display.csv" \
    >"$OUTDIR/sub1.log" 2>&1 &
PIDS+=($!)

echo "Running: strategy=$STRATEGY timeout=$TIMEOUT delay=$DELAY loss=${LOSS}% bw=$BW duration=${DURATION}s"
sleep "$DURATION"

# Stop processes gracefully (SIGTERM) and wait for CSV flush
for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
sleep 2
for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null || true; done
wait 2>/dev/null || true
PIDS=()  # prevent double-kill in EXIT trap

# Collect results
PUB_FRAMES=$(tail -n +2 "$OUTDIR/manifest.csv" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
SUB_OBJECTS=$(tail -n +2 "$OUTDIR/sub1_recv.csv" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
echo "  Published: $PUB_FRAMES frames"
echo "  Received:  $SUB_OBJECTS objects"
if [[ "$PUB_FRAMES" -gt 0 && "$SUB_OBJECTS" -gt 0 ]]; then
    RATIO=$(awk "BEGIN {printf \"%.2f\", $SUB_OBJECTS / $PUB_FRAMES * 100}")
    echo "  Delivery:  ${RATIO}%"
fi
