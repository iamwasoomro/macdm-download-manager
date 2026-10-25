#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/macdm-bridge.XXXXXX)
trap 'kill "${fixture_pid:-}" 2>/dev/null || true; rm -rf "$test_dir"' EXIT
cp Tests/bridge-main.swift "$test_dir/main.swift"
cp Sources/MacDM/ExtensionServer.swift "$test_dir/ExtensionServer.swift"
swiftc -module-cache-path /tmp/macdm-module-cache "$test_dir/main.swift" "$test_dir/ExtensionServer.swift" Sources/MacDM/{Models,Settings,VideoDetector}.swift -o "$test_dir/server"
"$test_dir/server" &
fixture_pid=$!
sleep 1
python3 Tests/bridge.test.py
