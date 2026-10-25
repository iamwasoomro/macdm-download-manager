#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/macdm-video.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
cp Tests/video-main.swift "$test_dir/main.swift"
cp Tests/fake-ytdlp.py "$test_dir/yt-dlp"
chmod +x "$test_dir/yt-dlp"
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
s = Path('Sources/MacDM/VideoDetector.swift').read_text()
a=s.index('    static var binaryPath: String {'); b=s.index('    static let knownHosts',a)
s=s[:a]+'    static var binaryPath: String { "'+str(root/'yt-dlp')+'" }\n'+s[b:]
a=s.index('    static var ffmpegPath: String? {'); b=s.index('    /// Download media',a)
s=s[:a]+'    static var ffmpegPath: String? { "/test/ffmpeg" }\n'+s[b:]
(root/'VideoDetector.swift').write_text(s)
PY
swiftc -module-cache-path /tmp/macdm-module-cache "$test_dir/main.swift" "$test_dir/VideoDetector.swift" -o "$test_dir/check"
export MACDM_VIDEO_LOG="$test_dir/args.jsonl" MACDM_VIDEO_DIR="$test_dir"
"$test_dir/check"
python3 - "$test_dir/args.jsonl" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
args = next(a for a in calls if 'https://example.test/video' in a)
for flag, value in [('--audio-format','mp3'),('--playlist-items','2'),('--limit-rate','2048')]:
    assert args[args.index(flag)+1] == value
assert '--embed-subs' in args and '--no-playlist' not in args and '--yes-playlist' in args
assert 'height<=720' not in args[args.index('-f')+1] # audio selection overrides video quality
print('PASS: audio conversion, subtitles, playlist item and bandwidth arguments')
PY
