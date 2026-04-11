#!/usr/bin/env bash
# netns-teardown.sh — Remove network namespace and veth pair.
# Must be run as root (sudo).
set -euo pipefail

ip netns del "moq-sub" 2>/dev/null || true
ip link del "veth-host" 2>/dev/null || true

echo "Cleaned up namespace 'moq-sub' and veth pair."
