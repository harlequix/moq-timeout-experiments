#!/usr/bin/env bash
# Container entrypoint: optional shaping via SHAPE env, then run the test.
# SHAPE="1mbit 50ms [loss] [limit]" (empty = no shaping); VIDEO, DURATION as in run-test.sh.
set -euo pipefail

if [ -n "${SHAPE:-}" ]; then
    # shellcheck disable=SC2086
    net-shape.sh $SHAPE
fi
exec run-test.sh "${VIDEO:-testdata/test_10s.mp4}" "${DURATION:-15}"
