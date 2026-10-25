<div align="center">

<img src="assets/icon.png" width="128" alt="MacDM icon">

# MacDM

**A native macOS download manager with an IDM-style Chrome extension — grab videos straight off the page.**

[![macOS](https://img.shields.io/badge/macOS-12%2B-black?logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5-orange?logo=swift&logoColor=white)](#build--install)
[![Chrome Extension](https://img.shields.io/badge/Chrome-Extension%20MV3-4285F4?logo=googlechrome&logoColor=white)](#chrome-extension)
[![yt-dlp](https://img.shields.io/badge/powered%20by-yt--dlp-6A9F58)](#requirements)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

*Parallel segmented downloads · persistent recovery · queues and scheduling · video and audio via yt-dlp*

</div>

---

## Screenshots

| Downloads window | Chrome extension popup |
| --- | --- |
| <img src="assets/app-window.png" width="560" alt="MacDM main window"> | <img src="assets/popup.png" width="300" alt="macdm Chrome extension popup"> |

<div align="center">

**IDM-style overlay** — a *Download this video* button appears directly on every player on any web page.

<img src="assets/overlay.png" width="640" alt="IDM-style download overlay on video players">

</div>

## Why MacDM

Browser downloads are one-speed-at-a-time, they land wherever Chrome decides, and saving a video from a streaming page is usually impossible. MacDM fixes all three:

- **Parallel by default** — files are split into 6 segments and downloaded concurrently, with automatic resume from the exact byte a failed transfer died at.
- **Videos from any page** — the Chrome extension detects players, playlists (HLS/DASH), and 1000+ video sites (YouTube, Vimeo, X, TikTok, Rumble, Bilibili…) via [yt-dlp](https://github.com/yt-dlp/yt-dlp), then hands them to the app.
- **Choose your media format** — MP4, MKV, WebM, original source, or audio-only M4A/MP3. ffmpeg handles video remux and audio conversion; resolution is never upscaled.
- **Organized automatically** — downloads are sorted into `~/Downloads/MacDM/` by category (Music, Videos, Programs, Compressed, Other) based on file name, extension, MIME type, or site — archives (zip, rar, 7z, tar, iso, …) always land in Compressed even when the download URL carries no file name.

## Features

**Native app (AppKit, zero dependencies beyond yt-dlp/ffmpeg)**

- Source-list sidebar with live category counts on a real blurred-sidebar material
- Card-style rows: status pill, progress bar with %, live speed, ETA, aggregate speed, detailed failures, retry / stop / reveal / delete
- Intake dialog for every incoming URL: title, estimated size, destination — *Start Download*, *Download Later* (paused), or *Cancel*
- Right-click menu: pause/resume, refresh download, reveal in Finder, remove (with optional file deletion)
- Persistent download history; interrupted transfers return paused after relaunch (browser cookies are not stored)
- Safe HTTP output: finished files are published after transfer, with numbered names when files already exist
- Search, state filters, sorting, bulk actions, FIFO queue ordering and priorities
- Automatic transient retries, network reconnection recovery, durable validated partial resume
- Configurable destinations, concurrency, connections, bandwidth limits, schedules, notifications and idle-sleep prevention
- Batch URL paste/import and drag-and-drop; SHA-256 integrity checks
- Video/audio format options, English subtitles, and playlist item selection
- Menu bar status item that fills while downloads run
- Manual Add Link sheet with quality picker (Best / 4K / 1440p / 1080p …) and live category preview

**Chrome extension (Manifest V3)**

- **On-player download button** — IDM-style overlay pinned to every sizeable `<video>`; direct files download instantly, blob/MSE players send the page through yt-dlp, and captured HLS/DASH playlists appear in a small menu on the button
- **Broader detection** — scans iframe players and open shadow roots, identifies extensionless HLS/DASH endpoints by response MIME, and refreshes detection whenever the popup opens
- **Toolbar popup** — auto-lists everything detected on the current tab: direct media with resolution badges, video-site pages as one row per available quality, and sniffed `.m3u8`/`.mpd` streams with HLS/DASH badges
- **Download interception** — supported file types (media, archives, documents, disk images…) are cancelled in Chrome and restarted in MacDM, with a toggle in the popup
- **Context menu** — *Download with macdm* on any link, page, video, or audio element
- **Browser context forwarding** — cookies, referrer, and user agent ride along, so authenticated/signed-in downloads work

## How it works

```
Chrome (any page)                         MacDM.app
┌──────────────────────────┐   POST       ┌─────────────────────────────┐
│ content script  overlay ─┼──127.0.0.1──►► ExtensionServer :7210      │
│ service worker  popup /  │   /add /info │   ├─ direct media ──► SegmentedDownloader
│ interception / HLS sniff │◄─────────────┤   └─ video pages ──► yt-dlp + ffmpeg
└──────────────────────────┘  quality    │        (remux → .mp4)       │
                              lookup     │   ~/Downloads/MacDM/<Cat>/  │
                                         └─────────────────────────────┘
```

The extension connects automatically to an HTTP server bound explicitly to `127.0.0.1:7210`, with extension-origin checks and bounded JSON requests. No pairing or connection setup is required. Download URLs and referrers remain in local history; cookies stay in memory.

## Build & install

**Requirements**

- macOS 12+ with Command Line Tools (`xcode-select --install`) — no Xcode needed
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) on disk — MacDM probes common locations (`/Library/Frameworks/Python.framework/…/bin/yt-dlp`, `/opt/homebrew/bin`, …)
- Optional but recommended: `brew install ffmpeg deno` — ffmpeg enables video+audio merging and `.mp4` remux; a JS runtime unlocks more YouTube formats

**Build the app**

```bash
git clone <this-repo> && cd mac-dm
swiftc $(ls Sources/MacDM/*.swift) Sources/MacDM/capture.c -o MacDM
cp MacDM MacDM.app/Contents/MacOS/MacDM
open MacDM.app
```

**Install the extension**

1. Launch Chrome and go to `chrome://extensions`
2. Enable **Developer mode** (top right)
3. **Load unpacked** → select the `chrome-extension/` folder
4. Keep MacDM running — the extension connects automatically on `127.0.0.1:7210`.

## Usage

| You want to… | Do this |
| --- | --- |
| Save a video playing on a page | Click the **⬇ Download this video** button on the player |
| Pick a quality for a video site | Click the toolbar icon — pick any listed quality |
| Paste a video link manually | **Add Video** → paste → pick a quality from the loader results |
| Download a normal file with MacDM | Just download it in Chrome — interception reroutes it |
| Grab a link without opening it | Right-click → **Download with macdm** |
| Queue something for later | Choose **Download Later** in the intake dialog, resume from the app |

## Queue, settings, and media controls

The **Actions** menu above the list provides **Settings**, **Pause All / Resume All**, **Add Multiple Links**, **Video Options / Playlist**, **Schedule Queue**, and **Clear Completed History**. Settings is also available with **⌘,**; **⌘D** opens batch intake and accepts clipboard links. Drag HTTP/HTTPS links into the list or import a UTF-8 file containing one URL per line.

Use the search field, state filter, and sort picker to find downloads. Queue order is FIFO; right-click a row to move it earlier/later or prioritize it. Use ⌘/⇧ to select multiple rows, then right-click to pause, resume, or remove the selection. Removing completed history preserves files; individual Remove offers an optional move to Trash.

Right-click **Download Options** to set a per-file speed limit, future start time, or expected SHA-256. Completed files offer **Verify SHA-256** to calculate or compare a checksum. Failed checksum verification retains the file for inspection and never automatically retries it.

Settings controls the download root, simultaneous files (1–12), connections per new file (1–16), transient retries (0–10), global bandwidth, notifications, and idle-sleep prevention. Zero bandwidth means unlimited. Bandwidth is conservatively divided across configured slots so mixed HTTP/video downloads respect the cap. Running yt-dlp limits take effect after pause/resume. Existing downloads retain their original folder and connection layout.

Queue scheduling uses one start and/or stop time in your Mac’s local time zone. A future queue start holds new transfers too; a stop pauses the queue until resumed. Per-file schedules persist with history. **MacDM must be running and the Mac awake**; scheduling does not install a system wake job.

**Video Options / Playlist** provides Source/MP4/MKV/WebM/M4A/MP3, audio-only, maximum height, and English subtitles when available. Load a playlist, then select its items (up to 500) before adding them as individual downloads. Format conversion and embedded subtitles require ffmpeg. Source remains available without conversion. Quality caps are enforced, and the actual downloaded height replaces the cap in the row when yt-dlp reports it.

History and validated partial HTTP downloads live in `~/Library/Application Support/MacDM/`. Interrupted tasks restore paused; scheduled items retain their schedules. Partial bytes are reused only when server validators and connection layout match; otherwise the file restarts safely. Servers that ignore ranges fall back to one connection. Transient whole-download failures retry with bounded backoff and recover after network reconnection. Authenticated downloads may need browser refresh after relaunch because cookies are not persisted.

## Validation

```bash
node Tests/detection.test.cjs
bash Tests/run-transfers.sh
bash Tests/run-video.sh
bash Tests/run-bridge.sh
```

The Swift suites use isolated temporary download folders, a separate settings domain, local fixture ports 17211/17212, and a fake yt-dlp for process/argument tests. Real-site availability still depends on yt-dlp, site authentication, and supported media; DRM playback is not downloadable by this app.

## Project layout

```
mac-dm/
├── Sources/MacDM/          # native app (pure AppKit + Foundation)
│   ├── AppDelegate/UI.swift        # window, sidebar, cards, status item
│   ├── DownloadManager.swift       # queue, concurrency, pause/resume
│   ├── SegmentedDownloader.swift   # 6-segment parallel engine + resume
│   ├── VideoDetector.swift         # yt-dlp wrapper, formats, mp4 remux
│   ├── DownloadIntake.swift        # confirmation dialog, size estimates
│   ├── ExtensionServer.swift       # HTTP server on 127.0.0.1:7210
│   └── Snapshot.swift              # --demo / --snapshot README tooling
├── chrome-extension/       # Manifest V3 extension
│   ├── overlay.js / .css           # IDM-style on-player button
│   ├── background.js               # scan, intercept, sniff HLS/DASH
│   └── popup.html / .js            # toolbar popup
├── assets/                 # README images
└── icon-generator.swift    # regenerates app + extension icons
```

## Known limitations

- Authenticated downloads may need to be resent from Chrome after relaunch because cookies are not persisted
- No code signing / notarization (unsigned local build)
- The extension is unpacked (developer mode), so Chrome reloads it manually after updates

## License

[MIT](LICENSE) — use it, fork it, ship it.
