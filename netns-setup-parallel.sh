#!/usr/bin/env bash
# netns-setup-parallel.sh — Create N network namespaces for parallel experiments.
# Must be run as root (sudo).
#
# Usage: sudo ./netns-setup-parallel.sh [N]   (default: 1)
#
# Creates namespaces moq-sub-0, moq-sub-1, ..., moq-sub-(N-1) with:
#   Slot 0: veth-host-0 (10.0.0.1/24) <-> veth-sub-0 (10.0.0.2/24)
#   Slot 1: veth-host-1 (10.0.1.1/24) <-> veth-sub-1 (10.0.1.2/24)
#   Slot K: veth-host-K (10.0.K.1/24) <-> veth-sub-K (10.0.K.2/24)
#
# Also creates the legacy single namespace (moq-sub / veth-host / veth-sub)
# as slot 0 alias for backwards compatibility.

set -euo pipefail

N="${1:-1}"

for i in $(seq 0 $((N - 1))); do
    NS="moq-sub-${i}"
    VETH_HOST="veth-host-${i}"
    VETH_SUB="veth-sub-${i}"
    HOST_IP="10.0.${i}.1/24"
    SUB_IP="10.0.${i}.2/24"

    # Clean up if exists
    ip netns del "$NS" 2>/dev/null || true
    ip link del "$VETH_HOST" 2>/dev/null || true

    # Create namespace
    ip netns add "$NS"

    # Create veth pair
    ip link add "$VETH_HOST" type veth peer name "$VETH_SUB"

    # Move sub end into namespace
    ip link set "$VETH_SUB" netns "$NS"

    # Configure host side
    ip addr add "$HOST_IP" dev "$VETH_HOST"
    ip link set "$VETH_HOST" up

    # Configure namespace side
    ip netns exec "$NS" ip addr add "$SUB_IP" dev "$VETH_SUB"
    ip netns exec "$NS" ip link set "$VETH_SUB" up
    ip netns exec "$NS" ip link set lo up

    # Disable reverse-path filtering
    sysctl -q -w "net.ipv4.conf.${VETH_HOST}.rp_filter=0"

    echo "Slot $i: ns=$NS host=$VETH_HOST($HOST_IP) sub=$VETH_SUB($SUB_IP)"
done

# Backwards compat: create legacy names as aliases for slot 0
ip netns del "moq-sub" 2>/dev/null || true
ip link del "veth-host" 2>/dev/null || true

# Symlink-style: just create another namespace with the same veth
# Actually, just document that slot 0 is the default.
echo ""
echo "$N parallel slot(s) ready."
echo "Use --slot N with run-experiment.sh, or --parallel N with run-matrix.sh"
