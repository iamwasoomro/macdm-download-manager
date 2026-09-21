# MacDM — macOS Download Manager (work log / handoff)

Native Swift download manager + Chrome extension. Status: **working v0.1**.
Located at `/Users/wasoomro/Desktop/mac-dm/`.

## What exists and is verified

### 1. Native app (`MacDM.app`, pure Swift + AppKit) — v0.2 UI
- **Build**: `swiftc $(ls Sources/MacDM/*.swift) -o MacDM` then copy into bundle:
  `cp MacDM MacDM.app/Contents/MacOS/MacDM`. Run with `open MacDM.app` or `./MacDM`.
- Sources in `Sources/MacDM/`:
  - `main.swift`, `AppDelegate.swift`, `UI.swift`, `AddPanel.swift` — redesigned AppKit UI:
    - Source-list sidebar on an NSVisualEffectView (.sidebar / behindWindow) so the desktop reads as a proper blur, with colored SF Symbol category icons + item counts;
      "All Downloads" row; clicking a category filters the list.
    - Content area: large header + item count, inset "card" rows (rounded,
      category icon, title + status pill, progress bar + %, retry/stop/reveal button).
    - Empty state per category ("No videos yet — add with ＋ or the Chrome extension").
    - Toolbar "＋ Add Download" button opens a sheet: URL field with live
      category preview ("Will be saved to Videos · video site detected") and a
      category override popup.
    - Menu bar status item (arrow.down.circle): turns filled/accent while
      downloads are active, menu shows current file + %, Open MacDM, Quit.
    - App icon at Resources/AppIcon.icns: blue→indigo gradient squircle, glass
      highlight, white arrow landing into an open tray (clear "download to
      tray" identity). Extension icons are the same glyph, chunkier/full-bleed,
      in 16/32/48/128 (icon16/32/48/128.png + icon.png). Regenerate with:
      `swiftc icon-generator.swift -o /tmp/makeicons && /tmp/makeicons /tmp/appicons /tmp/exticons`.
  - NOTE: `NSSplitViewItem(...)` / `NSScrollView(documentView:)` convenience
    inits are broken on this CLT ("takes no arguments" errors) — the split
    layout is hand-rolled with NSLayoutConstraints; don't "fix" it back.
  - `Models.swift` — `DownloadItem`, `DownloadCategory` (Music/Videos/Programs/Other),
    auto-detection by file extension / MIME / known video hosts. Files land in
    `~/Downloads/MacDM/<Category>/`.
  - `SegmentedDownloader.swift` — parallel multi-segment HTTP downloader.
    HEAD-probes size + `Accept-Ranges`, splits into 6 ranges, downloads
    concurrently, assembles on completion. Falls back to single stream if no
    Range support. Max 3 downloads in parallel (`DownloadManager`).
  - `VideoDetector.swift` — yt-dlp wrapper (binary at
    `/Library/Frameworks/Python.framework/Versions/3.13/bin/yt-dlp`).
    Detects video pages (YouTube, Vimeo, X, TikTok, SoundCloud, etc. — 1000+
    sites via yt-dlp), fetches metadata (title), downloads with progress parsing.
    Format `-f b/bv*+ba` (prefers pre-merged because ffmpeg is NOT installed —
    `bv*+ba` merging requires ffmpeg).
  - `ExtensionServer.swift` — raw-socket HTTP server on `127.0.0.1:7210`,
    CORS-enabled, accepts `POST /add {"url": "..."}` from the Chrome extension.
    **Verified working** (curl POST → app starts download).
- **Verified end-to-end**: 5 MB GNU tarball via 6 parallel segments → assembled,
  `tar tzf` validates. yt-dlp metadata fetch + full YouTube download verified.

### 2. Chrome extension `macdm` (`chrome-extension/`, Manifest V3)
- `manifest.json`, `background.js`, `popup.html/js`, generated `icon.png`.
- Features: context-menu "Download with MacDM" (link/page/video/audio), popup
  with paste-URL box, "Detect videos on this page" (scans `<video>` elements and
  media links via `chrome.scripting`), sends URLs to `127.0.0.1:7210/add`.
- Install: chrome://extensions → Developer mode → Load unpacked → select
  `chrome-extension/` folder. **Not yet loaded into Chrome** — do this to test.

## Environment gotchas (important)
- **No Xcode installed**, only Command Line Tools on macOS 27 (darwin arm64).
- **SwiftPM is broken on this CLT** (`libPackageDescription.dylib` exports no
  `Package` init → manifest link failure). That's why there is no `Package.swift`;
  compile directly with `swiftc`.
- **SwiftUI is unusable** with this CLT: `@State`/`@StateObject`/`@ObservedObject`
  etc. are macros and the `SwiftUIMacros` plugin is not shipped. UI is AppKit.
  Installing Xcode would fix both and allow migrating to SwiftUI.
- **ffmpeg not installed** (`which ffmpeg` empty). yt-dlp merging (bv*+ba) and
  some HLS/DRM-ish formats need it: `brew install ffmpeg`, then change
  `-f b/bv*+ba` → `-f bv*+ba/b` in `VideoDetector.swift`.
- yt-dlp warns: no JavaScript runtime — some YouTube formats may be missing.
  `brew install deno` fixes.

## v0.3 additions
- **Video-site flow**: direct HTTP attempt first (`VideoDetector.isDirectMedia`:
  media extension or video/audio content-type), then yt-dlp fallback. `usedYtDlp`
  on DownloadItem records which path was taken.
- **Quality selection**: Add sheet shows a Quality popup — yt-dlp `-J` lists
  formats, distinct heights populate the menu (Best available / 4K / 1440p /
  1080p…). Selector: `b[height<=H]/bv*[height<=H]+ba/b` (pre-merged preferred,
  ffmpeg still absent). Verified: 4K video capped at 360p fetched f396.mp4.
- **Extension auto-detect**: background.js scans every page on load
  (`chrome.tabs.onUpdated` + `chrome.scripting` — needs the `<all_urls>` host
  permission now in manifest.json), counts `<video>/<audio>/<source>` elements +
  media file links + video-site pages, and shows a blue badge count on the
  toolbar icon. Popup/context-menu flows unchanged. NOTE: extension must be
  reloaded in chrome://extensions to pick this up.

## v0.4 additions
- **Delete flow**: every download card has a trash button.
  - Incomplete/failed/active → confirmation dialog; confirm removes the item
    AND temporary files (`/tmp/macdm-<uuid>/` segments + yt-dlp `.part`
    leftovers matched by title prefix).
  - Completed → dialog with checkbox "Also delete file from disk"
    (unchecked by default); checked → file moved to Trash.
  - `DownloadManager.remove(item, deleteFileFromDisk:)`,
    `DownloadItem.cleanupTemporaryFiles()`.
- **Local server `/info`**: POST {"url":...} → {"title":..., "heights":[...]}
  via yt-dlp (20s timeout). `/add` now accepts optional "maxHeight" which is
  routed into `manager.add(url:maxHeight:)`.
- **Extension popup**: no more Detect button — the list populates itself on
  open from the background's cached auto-scan (`scans` Map keyed by tabId).
  Entries render as `name : quality` (badge); video-site pages ask the app
  `/info` and list one row per quality (4K/1440p/1080p…); clicking Download
  sends the URL + maxHeight. `<video>` elements report their real resolution.
  Reload the unpacked extension to pick this up.

## v0.6 additions
- **Intake dialog (extension sends)**: every URL arriving from Chrome now pops a
  confirmation — title, estimated size (yt-dlp format sizes for video pages,
  HEAD Content-Length otherwise), destination folder — with
  **Start Download / Download Later / Cancel**. See `DownloadIntake.swift`.
- **Download Later / paused**: `DownloadState.paused`; `manager.add(startNow:false)`
  inserts without pumping. The card shows an orange PAUSED pill and a play
  button; resume = `retry()` → queued → pump. Verified: stays paused with no
  network activity, then downloads on resume.
- **Add sheet**: two confirm buttons — Start Download (⏎) and Download Later.
- **Row spacing**: cards 84pt tall, title top 14, bottom margin guaranteed.

## v0.7 additions
- **Single-file downloads**: yt-dlp selector is now
  `b[height<=H]/b/bv*[height<=H]/bv*` (no ffmpeg) — combined stream if the site
  offers one, else the SINGLE best video-only stream. Never downloads the old
  video+audio pair (mp4 + webm). With ffmpeg present it merges instead
  (`bv*+ba/...`). NOTE: on this Mac yt-dlp has NO JS runtime (deno/node/bun
  absent) so YouTube exposes no combined formats → single video-only mp4
  (no audio track) is the best single-file result. `brew install ffmpeg deno`
  would enable true merged audio+video; selector picks it up automatically.
  Verified via `yt-dlp --simulate` (no data downloaded, bandwidth-friendly).
- **Card title**: video rows now read `VIDEO_NAME | MP4 | 1080p` —
  `DownloadItem.displayTitle` from `videoFormat` (captured via
  `--print after_move:filepath`) + `videoQuality` (from maxHeight or "Best").

## v0.8 additions — referrer & refresh workflow
- **Referrer tracking**: the extension sends `referrer` (page URL) with every
  download (context menu, popup rows, manual paste); `/add` accepts it and
  `DownloadItem.referrerURL` stores it. `estimatedSize` from intake is stored
  for later same-file checks.
- **Right-click menu** on any download card: Pause/Resume (state-aware),
  Refresh Download… (paused/failed only), Reveal in Finder (completed),
  Remove…. Implemented via NSMenuDelegate on the table (`menuNeedsUpdate`,
  `tableView.clickedRow`).
- **Refresh dialog** (`RefreshUI.swift` RefreshPanelController): shows current
  URL, editable New URL field, "Update URL" (runs size confirmation then
  `manager.updateURL` — swaps URL, cleans temp files, restarts) and
  **"Refresh Download from Browser"** — opens `referrerURL` (or file URL) in
  the default browser.
- **Browser round-trip matching**: when a new URL arrives with a referrer
  equal to a paused/failed item's referrer, `DownloadIntake.refreshFromBrowser`
  shows a **"Please wait" spinner panel** (WaitPanel) while estimating, then a
  size-comparison dialog: "Same file detected" (sizes equal) / "Different file
  detected" (sizes differ, both shown) / unknown — with Update Download /
  Add as New Download / Cancel. Update swaps the URL on the existing item.
- `DownloadManager.pause(_:)` (cancels task, marks paused — segmented engine
  leaves `.paused` untouched on cancellation) and `updateURL(_:newURL:)`.
  Pause of a yt-dlp item marks paused but the child process may still finish
  in the background and flip state to completed — known limitation.

## v0.9 additions
- **Completed cards hide the progress bar** (and the % label); the subtitle
  shows a single size, not "x / y".
- **Size reconciliation**: on completion the byte counters are taken from the
  real file on disk — segmented downloads stat the assembled file, yt-dlp
  downloads stat the `--print after_move:filepath` result. Fixes the "0 KB in
  manager while the file is non-empty" case (yt-dlp single-format downloads
  print no progress table, so parsed sizes stayed 0).

## v0.10 additions — download interception & browser auth
- **Chrome download interception**: `chrome.downloads.onCreated` in
  background.js — supported file types (media, pdf/epub/doc(x)/ppt(x)/xls(x)/
  txt/rtf/csv/mobi, archives/dmg/iso/exe, torrent…) are CANCELLED in Chrome
  (downloads.cancel + erase) and sent to macdm instead. Toggle in the popup
  ("Send Chrome downloads of supported files to macdm", stored in
  chrome.storage.local `interceptDownloads`, default ON). New permissions:
  "downloads", "cookies" (reload the unpacked extension to grant).
- **Browser context forwarding**: every send includes `cookies`
  (chrome.cookies.getAll for the URL, "name=value; …") and `userAgent`.
  App side: `IncomingDownload` struct; `DownloadItem.cookies/userAgent`;
  segmented requests carry `Cookie`/`User-Agent` headers (verified with a
  localhost echo server); yt-dlp gets `--add-headers "Cookie: …"` +
  `--user-agent …` on both download and metadata fetch (`/info` accepts
  cookies too). Intake estimate uses them for HEAD.
- `VideoDetector.headerArgs(cookies:userAgent:)` builds the yt-dlp flags.

## v0.11 — blob: stream handling
- `scanPage()` in background.js now EXCLUDES `blob:`/`data:` video sources —
  they are MediaSource streams that only resolve inside the tab and can't be
  fetched by any external downloader (they showed up as UUID-named entries
  like `58cb3444-…` with a fake quality badge). The scans cache carries a
  `blobVideos` count; on video sites the popup shows the page's yt-dlp
  quality rows instead; on other sites the popup's status line explains blob
  streams can't be fetched directly and offers the page link ("send page")
  which yt-dlp may still resolve.

## v0.12 — quality lookup hardening + popup hygiene
- `/info` now retries transient yt-dlp failures (3 attempts, 12s each) and
  serves a 5-minute in-memory cache (NSLock-guarded, per URL) — the popup no
  longer degrades to "best available" because of one flaky metadata fetch.
  Verified: second identical call returns in 11ms from cache.
- popup.js: typing into the URL box clears the detected list + status when the
  text no longer matches the current page URL (stale entries from the previous
  scan are erased).

## v0.13 — resume + speed
- **Segment resume**: temp segment files under `/tmp/macdm-<uuid>/` are KEPT
  across retries; each segment continues via `Range: (start+existing)-(end)`
  and appends to the partial file. Segments already complete on disk are
  skipped, so a download that failed at 99% resumes from 99%, not 0.
  Manual retry AND an in-flight auto-retry (3 attempts, 1–3s backoff) both
  resume. Progress is initialized from existing bytes, so the bar starts
  where the previous attempt died.
- **Completeness check**: a segment stream that ends short of its range —
  even when the server declares a matching short Content-Length — throws,
  which triggers the resume path (found via a fault-injection local test).
- **Speed display**: `DownloadItem.recordProgress` maintains a smoothed
  (EMA) bytes/sec sampled at most every 0.5s; the card subtitle shows
  "· 12.4 MB/s" while downloading (segmented, single-stream and yt-dlp paths
  all feed it). Zeroed when a download finishes/fails.
- Verified against a local fault-injection server (one connection cut at the
  90% mark + throttled delivery): auto-retry resumed the cut segment from
  byte 15099494, file assembled complete (16777216/16777216), speed read
  13 MB/s. No external bandwidth used.

## v0.14 — Compressed category
- New `DownloadCategory.compressed` (teal `doc.zipper` icon): zip/tar/gz/bz2/
  xz/7z/rar/iso/tgz/zst/jar + zip/gzip/compressed MIME types. Programs keeps
  dmg/pkg/exe/app/deb/rpm/apk/ipa. Saves to ~/Downloads/MacDM/Compressed/.

## v0.15 — replay/burst protection
- Chrome side: interception now skips downloads whose `startTime` is older
  than 60s (Chrome re-creates unfinished downloads from previous sessions on
  startup, replaying onCreated for each) and de-dupes URLs already
  intercepted this session (`intercepted` Set, capped at 500).
- App side: `DownloadIntake` burst guard — max 5 intake dialogs per 20s
  window; the rest are dropped with a console log. Reload the extension to
  pick up the background.js change.

## v0.16 — icon/popup show videos only
- The toolbar badge and popup list ONLY videos now: `scanPage()` no longer
  collects `a[href]` links, `fileLinks()` is gone, and the scans cache dropped
  its `files` array. Badge count = direct `<video>/<audio>/<source>` media +
  1 if the page is a known video site (yt-dlp page entry). PDF/ZIP/DMG-style
  links are no longer detected or listed anywhere.
- Non-video files are captured ONLY when the browser actually starts
  downloading them — the existing `chrome.downloads.onCreated` interceptor
  (cancel + erase in Chrome → POST /add) is unchanged and remains the sole
  path for them. `FILE_EXTENSIONS`/`isSupportedFile` stay for that interceptor.
- popup.js: file-link rows removed; empty state reads "No videos detected on
  this page". Reload the unpacked extension to pick this up.

## v0.17 — HLS/DASH capture + mp4 output (ffmpeg installed)
- **ffmpeg 9.0.2 installed** (`brew install ffmpeg` → /opt/homebrew/bin/ffmpeg,
  the path VideoDetector probes). This enables the long-blocked video+audio
  MERGE path (selector now prefers `bv*+ba`) — fixes the v0.7 "video-only, no
  audio" limitation — and the mp4 conversion below. Also installed
  `curl_cffi` into yt-dlp's Python 3.13 (pip) enabling `--impersonate`.
- **Every yt-dlp download ends as .mp4**: `--ffmpeg-location <path>` is always
  passed (GUI apps don't inherit the shell PATH), plus `--merge-output-format
  mp4` (merged av) and `--remux-video mp4` (single-format files: HLS .ts,
  .webm, .mkv). Remux is a STREAM COPY — no re-encode — so the downloaded
  resolution is preserved exactly: a 240p source yields a 240p mp4, never
  upscaled. Verified end-to-end with a locally generated 426x240 HLS stream:
  yt-dlp → playlist.mp4, ffprobe confirms mp4/h264 426x240 + aac audio.
- **Rumble & friends**: rumble.com, odysee.com, bitchute.com, bilibili.com
  added to VIDEO_HOSTS (extension) and knownHosts (app). Rumble 403s plain
  HTTP clients, so VideoDetector probes once for curl_cffi impersonation and
  appends `--impersonate chrome` to /info and download when available
  (coexists with the forwarded cookies/UA). Verified: the user's Rumble URL
  extracts 180p–1080p; capped maxHeight=240 selects the closest ≤240 stream
  (180p timeline + audio), uncapped selects 1080p — both mp4.
- **Extension captures m3u8/m3u/mpd playlists** (HLS/DASH): new
  `chrome.webRequest.onBeforeRequest` observer (permission "webRequest",
  observe-only) buckets playlist URLs per tab (deduped, capped at 30);
  they merge into the scan cache, count on the badge, and the popup lists
  them as rows with an HLS/DASH badge. Restart via chrome://extensions
  reload (grant the new permission).
- **App routing for playlists**: `VideoDetector.isStreamURL` (m3u8/m3u/mpd);
  DownloadManager routes stream URLs into the yt-dlp path (SegmentedDownloader
  would only save the playlist text), isDirectMedia refuses them (some servers
  report m3u8 as audio/x-mpegurl), DownloadIntake.estimate uses yt-dlp
  metadata for them, and DownloadCategory.videos treats them as videos.

## v0.18 — IDM-style "Download this video" overlay on page players
- **New content script** `chrome-extension/overlay.js` + `overlay.css`,
  registered in manifest.json (`content_scripts`, matches http/https,
  `all_frames: true`, `document_idle`; manifest version bumped to 0.2.0).
  On every page, a floating gradient pill ("⬇ Download this video") is pinned
  to the top-right of each sizeable `<video>` (≥200×140 — smaller players are
  treated as ads/trackers), IDM-style. Tiny frames (innerWidth/Height < 200×140)
  are skipped entirely. Each pill has a small × to dismiss it for the session.
- **Click behavior**: direct http(s) src → that URL is sent via the existing
  `macdm-add` message (referrer = page URL; background adds cookies/UA; the
  app shows its normal intake dialog). blob:/empty players (YouTube-style
  MSE players) → the PAGE url is sent, which the app resolves via yt-dlp —
  unless the background's webRequest observer has captured HLS/DASH playlists
  for this tab, in which case a small menu lists them (name + HLS/DASH badge)
  plus a "This page · resolved by yt-dlp" row. New background message
  `macdm-streams` returns `streamEntries(sender.tab.id)` for this.
- **Lifecycle**: MutationObserver-driven sweep every 2.5 s (also catches videos
  inside open shadow roots and players added late by SPA code), prunes
  overlays whose video left the DOM, repositions on scroll (capture) /
  resize / fullscreenchange / per-video ResizeObserver. Pill shows
  "Sending…" → "Sent to macdm ✓" (green) or "macdm app is not running" (red),
  then reverts; resolution badge (1080p / 4K) shown for direct files;
  tooltip previews the URL that will be sent.
- **Testing status**: verified statically (manifest valid, reuses the proven
  `macdm-add`/`/add` flow end-to-end); automated browser verification was
  started but abandoned — this session has no macOS Accessibility/Screen
  Recording grant, branded Chrome 153 ignores `--load-extension`, and Chrome
  for Testing was downloaded to /tmp/chrome-mac-arm64 for manual testing
  (delete freely). A throwaway test page with direct/blob/late/small videos
  lives at /tmp/macdm-test/test.html (serve with `python3 -m http.server`).
  **Reload the unpacked extension in chrome://extensions to pick this up.**

## v0.18.1 — same-page quality dedupe fix
- **Bug**: in the extension popup, clicking Download on 1080p worked, but a
  second click on a different quality (e.g. 360p) silently did nothing.
- **Cause**: `DownloadManager.add` deduped on URL alone — every quality row of
  a video page sends the SAME page URL (only `maxHeight` differs), so after
  the first add, all further quality picks hit the guard and returned nil.
- **Fix**: dedupe key is now (url, maxHeight) — same URL at a different cap is
  a distinct download. Also baked the cap into the yt-dlp output template
  (`Title (360p).mp4`) so qualities don't collide on disk (yt-dlp would
  otherwise see the existing `Title.mp4` and report "already downloaded");
  uncapped "Best" keeps saving as `Title.mp4`. Clicking the SAME quality twice
  still dedupes. App restarted with the rebuilt binary.

## v0.19 — professional README + screenshot tooling
- **README.md**: hero icon + shields.io badges, screenshots (app window,
  extension popup, IDM overlay), feature lists, architecture ASCII diagram,
  build/install/usage tables, project layout, known limitations, MIT license
  (LICENSE file added). Images in `assets/` (icon.png 512, app-window.png 2x,
  popup.png, overlay.png).
- **Snapshot tooling** (`Snapshot.swift` + `capture.c`, hook at the end of
  AppDelegate.applicationDidFinishLaunching): `MacDM --demo` injects 5
  cosmetic demo rows (no network), `--snapshot <path>` renders the window to
  a 2x PNG after 1.6 s and quits. capture.c reaches the SDK-removed
  CGWindowListCreateImage through dlsym — capturing your OWN window needs no
  Screen Recording permission. Regenerate README shots with:
  `./MacDM --demo --snapshot assets/app-window.png`.
- **Extension screenshots**: Chrome for Testing (downloaded to
  /tmp/chrome-mac-arm64; branded Chrome 153 ignores --load-extension) +
  CDP Page.reload after launch (content scripts don't retro-inject into a
  page that loaded before the extension registered — that was the "0
  overlays" mystery), Page.bringToFront before Page.captureScreenshot
  (occluded windows never produce a frame otherwise), and
  chrome.action.openPopup() from the service worker (works headlessly) for
  the authentic popup capture.
- **UI fix found via screenshot**: the downloads table showed a stray
  default "Field" column header — `tableView.headerView = nil` now, same as
  the sidebar outline.

## Known gaps / next steps
1. Load + test the Chrome extension in Chrome (permissions already include
   `host_permissions` for 127.0.0.1:7210; service worker uses fetch POST).
2. `DownloadItem` list is in-memory only — no persistence across launches.
   Persist `items` (they're already `Codable`-adjacent) to JSON in App Support.
3. No pause/resume of partial segmented downloads (cancel discards temp segments
   in `/tmp/macdm-<uuid>/`; resume would re-request partial ranges).
4. (DONE v0.5) Live intra-segment progress: `DownloadItem.setSegmentDownloaded`
   recomputes receivedBytes as the sum over segments every ~100ms, so the
   progress bar tracks total file completion during parallel downloads.
5. Music category from yt-dlp is rudimentary (SoundCloud + duration < 10 min).
   Use `info.extractor` table for better classification.
6. No .app icon, no code signing/notarization, no menu bar/clipboard watcher.
   `Pasteboard` helper in old SwiftUI file was removed with it — Cmd-D paste
   shortcut is gone (AppKit toolbar field works).
7. `ExtensionServer` single-shot per connection, no auth token — fine for
   localhost but a local token check would harden it.
8. UI testing was headless-ish (app launched in background); a human should
   eyeball the window once.
