#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/macdm-tests.XXXXXX)
trap 'kill "${fixture_pid:-}" 2>/dev/null || true; rm -rf "$test_dir"' EXIT
cp Tests/transfer-main.swift "$test_dir/main.swift"
# Isolate destinations without changing the production download location.
python3 - "$test_dir" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
source = pathlib.Path('Sources/MacDM/Models.swift').read_text()
source = source.replace('DownloadSettings.shared.folder', 'URL(fileURLWithPath: "' + str(root / 'downloads') + '", isDirectory: true)')
source = source.replace('FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]', 'URL(fileURLWithPath: "' + str(root / 'support') + '", isDirectory: true)')
(root / 'Models.swift').write_text(source)
settings = pathlib.Path('Sources/MacDM/Settings.swift').read_text().replace('UserDefaults.standard', 'UserDefaults(suiteName: "MacDM.Regression")!')
(root / 'Settings.swift').write_text(settings)
PY
swiftc -module-cache-path /tmp/macdm-module-cache "$test_dir/main.swift" "$test_dir/Models.swift" "$test_dir/Settings.swift" Sources/MacDM/{DownloadManager,DownloadHistory,DownloadServices,SegmentedDownloader,VideoDetector}.swift -o "$test_dir/check"
python3 Tests/transfer-server.py &
fixture_pid=$!
sleep 1
"$test_dir/check"
