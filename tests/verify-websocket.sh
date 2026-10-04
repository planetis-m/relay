#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
for mode in debug release danger; do
  nim c -r -d:"$mode" --nimcache:"build/cache-unit-$mode" \
    --out:"build/unit-$mode" tests/test_websocket.nim
  nim c -d:"$mode" --nimcache:"build/cache-worker-$mode" \
    --out:"build/websocket-worker-probe-$mode" tests/websocket_worker_probe.nim
  WEBSOCKET_WORKER_PROBE="build/websocket-worker-probe-$mode" \
    node --test --experimental-test-isolation=none tests/websocket-worker.test.mjs
done
