#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
exe=""
if [ "${OS:-}" = "Windows_NT" ]; then exe=".exe"; fi
for mode in debug release danger; do
  nim c -r -d:"$mode" --nimcache:"build/cache-unit-$mode" \
    --out:"build/unit-$mode$exe" tests/test_websocket.nim
  nim c -d:"$mode" --nimcache:"build/cache-worker-$mode" \
    --out:"build/websocket-worker-probe-$mode$exe" tests/websocket_worker_probe.nim
  WEBSOCKET_WORKER_PROBE="build/websocket-worker-probe-$mode$exe" \
    node --test --experimental-test-isolation=none tests/websocket-worker.test.mjs
done
