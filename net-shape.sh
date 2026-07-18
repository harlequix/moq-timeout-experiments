#!/usr/bin/env bash
# Shape loopback inside the container (needs NET_ADMIN).
# Usage: net-shape.sh <rate> <delay> [loss] [limit]   e.g. net-shape.sh 1mbit 50ms 0% 100
#        net-shape.sh unlimited <delay> [loss] [limit]  delay/loss without rate limiting
#        net-shape.sh off                             remove shaping
set -euo pipefail

DEV="${DEV:-lo}"

if [ "${1:-}" = "off" ]; then
    tc qdisc del dev "$DEV" root 2>/dev/null || true
    echo "shaping removed from $DEV"
    exit 0
fi

RATE="${1:?rate, e.g. 1mbit, or unlimited}"
DELAY="${2:?delay, e.g. 50ms}"
LOSS="${3:-0%}"
LIMIT="${4:-1000}" # netem queue length in packets

RATE_ARGS=(rate "$RATE")
[ "$RATE" = "unlimited" ] && RATE_ARGS=()

tc qdisc del dev "$DEV" root 2>/dev/null || true
tc qdisc add dev "$DEV" root handle 1: netem delay "$DELAY" loss "$LOSS" "${RATE_ARGS[@]}" limit "$LIMIT"
tc qdisc show dev "$DEV"
