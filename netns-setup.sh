#!/usr/bin/env bash
# netns-setup.sh — Create network namespace + veth pair for MoQ experiments.
# Must be run as root (sudo).
#
# Topology:
#   Host side:  veth-host  10.0.0.1/24  (relay binds downstream here)
#   Namespace:  veth-sub   10.0.0.2/24  (subscribers connect from here)
#
# netem is applied on veth-sub (inside the namespace) so that traffic
# FROM relay TO subscriber experiences the configured impairment.
# Return traffic (subscriber→relay) is also impaired, which is realistic
# for a WAN link.

set -euo pipefail

NS="moq-sub"
VETH_HOST="veth-host"
VETH_SUB="veth-sub"
HOST_IP="10.0.0.1/24"
SUB_IP="10.0.0.2/24"

# Idempotent: clean up first if exists
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

# Disable reverse-path filtering (needed for ns traffic to work)
sysctl -q -w net.ipv4.conf."$VETH_HOST".rp_filter=0

echo "Network namespace '$NS' ready."
echo "  Host:      $VETH_HOST ($HOST_IP)"
echo "  Namespace: $VETH_SUB ($SUB_IP)"
echo ""
echo "Apply netem:  sudo ip netns exec $NS tc qdisc add dev $VETH_SUB root netem delay 40ms loss 2%"
echo "Run in ns:    sudo ip netns exec $NS sudo -u \$USER <command>"
