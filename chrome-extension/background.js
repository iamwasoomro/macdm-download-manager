const MACDM_URL = "http://127.0.0.1:7210/add";
const MACDM_INFO = "http://127.0.0.1:7210/info";

const VIDEO_HOSTS = [
  "youtube.com", "youtu.be", "vimeo.com", "twitter.com", "x.com",
  "tiktok.com", "instagram.com", "facebook.com", "twitch.tv",
  "soundcloud.com", "dailymotion.com", "reddit.com", "bandcamp.com",
  "rumble.com", "odysee.com", "bitchute.com", "bilibili.com",
  "kick.com"
];

// File types that should be handed to macdm instead of Chrome's downloader.
const FILE_EXTENSIONS = [
  // media (m3u8/mpd playlists too — macdm runs them through yt-dlp)
  "mp4","mkv","mov","avi","webm","flv","m4v","mp3","m4a","flac","wav",
  "aac","ogg","opus","ts","m3u8","m3u","mpd",
  // documents
  "pdf","epub","mobi","azw3","djvu","doc","docx","ppt","pptx","xls","xlsx",
  "txt","rtf","csv","md",
  // programs / archives
  "dmg","pkg","zip","tar","gz","bz2","xz","7z","rar","iso","deb","rpm","apk","exe",
  "tgz","tbz2","txz","zst","jar","lz4","lzma","cab","lzh","arj",
  // other
  "torrent","jar","bin"
];

const INTERCEPT_KEY = "interceptDownloads";
const INTERCEPT_DEFAULT = true;

function isVideoSite(url) {
  try {
    const host = new URL(url).hostname.replace(/^www\./, "");
    return VIDEO_HOSTS.some(h => host === h || host.endsWith("." + h));
  } catch { return false; }
}

function extOf(urlOrPath) {
  try {
    const path = urlOrPath.includes("://")
      ? new URL(urlOrPath).pathname
      : urlOrPath;
    return path.toLowerCase().split(".").pop() || "";
  } catch { return ""; }
}

function isSupportedFile(url, filename) {
  const ext = extOf(filename || "") || extOf(url || "");
  return FILE_EXTENSIONS.includes(ext);
}

/** Runs in the page: video/audio sources with their resolution when known.
 *  blob:/data: sources are MediaSource streams that only resolve inside this
 *  tab — they cannot be fetched by any external downloader, so they are
 *  counted but not listed (the page link itself goes through yt-dlp).
 *  Also regexes the page source for embedded HLS/DASH playlists: sites like
 *  Kick ship the tokenized master.m3u8 in the server-rendered HTML, so it is
 *  offerable before playback and survives service-worker restarts (the
 *  webRequest capture loses history when the worker idles out).
 *  Non-video files are deliberately NOT scanned — the icon only ever shows
 *  videos; other files are picked up by the downloads.onCreated interceptor
 *  when the browser actually starts downloading them. */
function scanPage() {
  const out = { videos: [], blobVideos: 0, sourceStreams: [] };
  const seen = new Set();
  function addMedia(raw, height = 0) {
    if (!raw) return;
    if (/^(blob|data):/.test(raw)) { out.blobVideos++; return; }
    try {
      const url = new URL(raw, location.href);
      if (!/^https?:$/.test(url.protocol) || seen.has(url.href)) return;
      seen.add(url.href);
      let name = url.pathname.split("/").pop() || "media";
      try { name = decodeURIComponent(name); } catch {}
      out.videos.push({ src: url.href, name: name.slice(0, 70), height });
    } catch {}
  }
  function walk(root) {
    root.querySelectorAll("video, audio").forEach(v => {
      addMedia(v.currentSrc || v.src, v.videoHeight || 0);
      v.querySelectorAll("source").forEach(source => addMedia(source.src, v.videoHeight || 0));
    });
    root.querySelectorAll("*").forEach(el => { if (el.shadowRoot) walk(el.shadowRoot); });
  }
  walk(document);
  document.querySelectorAll('meta[property="og:video"], meta[property="og:video:url"], meta[property="og:video:secure_url"], meta[itemprop="contentUrl"]').forEach(meta => {
    // Only concrete media URLs: og:video often points at an HTML embed.
    if (/\.(mp4|webm|mov|m4v)([?#]|$)/i.test(meta.content)) addMedia(meta.content);
  });
  const urls = new Set();
  const re = /https:(?:\\u002F|\\\/|\/)[^"'`\s<>\\]*?\\?\.m(?:3u8|pd)[^"'`\s<>\\]*/gi;
  for (const m of document.documentElement.innerHTML.matchAll(re)) {
    let u = m[0]
      .replace(/\\u002F/gi, "/")
      .replace(/\\\//g, "/")
      .replace(/\\(?=\r?\n)/g, "")
      .replace(/\\+/g, "")
      .replace(/[.,;:!?)\]}'"]+$/, "");
    if (/^https:\/\/[^/]+\/.+/i.test(u)) urls.add(u);
    if (urls.size >= 10) break;
  }
  for (const src of urls) {
    let name = "stream";
    try { name = decodeURIComponent(new URL(src).pathname.split("/").pop() || name).slice(0, 70); } catch {}
    out.sourceStreams.push({ src, name, kind: /\.mpd(\?|#|$)/i.test(src) ? "DASH" : "HLS" });
  }
  return out;
}

async function scanTab(tabId) {
  const results = await chrome.scripting
    .executeScript({ target: { tabId, allFrames: true }, func: scanPage })
    .catch(() => null);
  const out = { videos: [], blobVideos: 0, sourceStreams: [] };
  const videos = new Map(), playlists = new Map();
  for (const frame of results || []) {
    const found = frame.result;
    if (!found) continue;
    out.blobVideos += found.blobVideos || 0;
    for (const video of found.videos || []) {
      if (!videos.has(video.src) || video.height > videos.get(video.src).height) videos.set(video.src, video);
    }
    for (const stream of found.sourceStreams || []) playlists.set(stream.src, stream);
  }
  out.videos = [...videos.values()];
  out.sourceStreams = [...playlists.values()];
  return out;
}

/** Browser context for the app: cookies + user agent for this URL. */
async function browserContext(url) {
  const out = { cookies: null, userAgent: navigator.userAgent };
  try {
    const cookies = await chrome.cookies.getAll({ url });
    if (cookies.length) {
      out.cookies = cookies.map(c => `${c.name}=${c.value}`).join("; ");
    }
  } catch { /* cookies permission not granted */ }
  return out;
}

/** Auto-scan on every page load; cache results and show a badge count.
 *  Badge/popup show videos only — file links are never listed. */
const scans = new Map(); // tabId -> {url, title, videos, streams, blobVideos, isVideoSite}

function streamEntries(tabId) {
  const m = streams.get(tabId);
  if (!m) return [];
  return [...m.entries()].map(([url, kind]) => {
    let name = "stream";
    try { name = decodeURIComponent(new URL(url).pathname.split("/").pop() || name).slice(0, 70); } catch {}
    return { src: url, name, kind };
  });
}

/** Captured network playlists + ones embedded in the page source, deduped. */
function mergedStreams(tabId, sourceStreams) {
  const byUrl = new Map();
  for (const s of sourceStreams || []) byUrl.set(s.src, s);
  for (const s of streamEntries(tabId)) if (!byUrl.has(s.src)) byUrl.set(s.src, s);
  return [...byUrl.values()];
}

function setBadge(tabId, scan) {
  const count = (scan.videos?.length || 0) + (scan.streams?.length || 0) + (scan.isVideoSite ? 1 : 0);
  if (count > 0) {
    chrome.action.setBadgeText({ text: String(Math.min(count, 99)), tabId });
    chrome.action.setBadgeBackgroundColor({ color: "#0a84ff", tabId });
  } else {
    chrome.action.setBadgeText({ text: "", tabId });
  }
}

async function autoScan(tabId, url, title) {
  if (!url || !url.startsWith("http")) return;
  const found = await scanTab(tabId);
  const scan = {
    url, title: title || url,
    videos: found.videos || [],
    sourceStreams: found.sourceStreams || [],
    streams: mergedStreams(tabId, found.sourceStreams),
    blobVideos: found.blobVideos || 0,
    isVideoSite: isVideoSite(url),
  };
  scans.set(tabId, scan);
  setBadge(tabId, scan);
}

// ---- Live stream (HLS/DASH) capture ----
// Players (hls.js, Shaka, native <video>) fetch .m3u8/.mpd playlists over the
// network — the only reliable way to see them is observing the tab's requests.
// Each captured playlist is surfaced as a video entry for its tab.
const STREAM_RE = /\.(m3u8|m3u|mpd)(\?|#|$)/i;
const streams = new Map(); // tabId -> Map(url -> true)

function captureStream(details, kind) {
  if (details.tabId < 0 || !/^https?:/.test(details.url)) return;
  let m = streams.get(details.tabId);
  if (!m) { m = new Map(); streams.set(details.tabId, m); }
  m.set(details.url, kind);
  if (m.size > 30) m.delete(m.keys().next().value);
  const scan = scans.get(details.tabId);
  if (scan) {
    scan.streams = mergedStreams(details.tabId, scan.sourceStreams);
    setBadge(details.tabId, scan);
  }
}

chrome.webRequest.onBeforeRequest.addListener(details => {
  if (STREAM_RE.test(details.url)) captureStream(details, /\.mpd([?#]|$)/i.test(details.url) ? "DASH" : "HLS");
}, { urls: ["<all_urls>"] });

// Signed CDN endpoints often have no file extension. Response MIME identifies them.
chrome.webRequest.onHeadersReceived.addListener(details => {
  if (details.statusCode < 200 || details.statusCode >= 300) return;
  const mime = details.responseHeaders?.find(h => h.name.toLowerCase() === "content-type")?.value?.split(";")[0].trim().toLowerCase();
  if (["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl"].includes(mime)) captureStream(details, "HLS");
  else if (mime === "application/dash+xml") captureStream(details, "DASH");
}, { urls: ["<all_urls>"] }, ["responseHeaders"]);

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "macdm-link",
    title: "Download with macdm",
    contexts: ["link", "page", "video", "audio"],
  });
  chrome.storage.local.setAccessLevel?.({ accessLevel: "TRUSTED_CONTEXTS" });
  chrome.storage.local.get(INTERCEPT_KEY).then(stored => {
    if (stored[INTERCEPT_KEY] == null) chrome.storage.local.set({ [INTERCEPT_KEY]: INTERCEPT_DEFAULT });
  });
});

chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
  if (change.status === "loading") {
    scans.delete(tabId); streams.delete(tabId);
    chrome.action.setBadgeText({ text: "", tabId });
  }
  if ((change.status === "complete" || change.url) && tab.url) {
    autoScan(tabId, tab.url, tab.title);
  }
});

chrome.tabs.onRemoved.addListener(tabId => { scans.delete(tabId); streams.delete(tabId); });

// ---- Download interception: supported files go to macdm, not Chrome ----

const intercepted = new Set(); // URLs handled this session

async function interceptEnabled() {
  const stored = await chrome.storage.local.get(INTERCEPT_KEY);
  return stored[INTERCEPT_KEY] ?? INTERCEPT_DEFAULT;
}

chrome.downloads.onCreated.addListener(async downloadItem => {
  if (!(await interceptEnabled())) return;
  const url = downloadItem.finalUrl || downloadItem.url || "";
  if (!url.startsWith("http")) return;                 // skip blob:/data:
  if (!isSupportedFile(url, downloadItem.filename)) return;

  // Chrome re-creates unfinished downloads from previous sessions on startup,
  // replaying onCreated for each — never intercept those, nor repeats.
  const startedAt = downloadItem.startTime ? new Date(downloadItem.startTime).getTime() : 0;
  if (startedAt && Date.now() - startedAt > 60000) return;
  if (intercepted.has(url)) return;
  intercepted.add(url);
  if (intercepted.size > 500) intercepted.delete(intercepted.values().next().value);

  // stop Chrome's own download and wipe it from its list
  try { await chrome.downloads.cancel(downloadItem.id); } catch {}
  try { await chrome.downloads.erase({ id: downloadItem.id }); } catch {}

  const ctx = await browserContext(url);
  sendToMacDM(url, null, downloadItem.referrer || null, ctx.cookies, ctx.userAgent,
              { filename: downloadItem.filename, mime: downloadItem.mimeType });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== "macdm-link") return;
  const url = info.linkUrl || info.srcUrl || info.pageUrl || tab?.url;
  if (!url) return;
  const ctx = await browserContext(url);
  await sendToMacDM(url, null, info.pageUrl || tab?.url || null, ctx.cookies, ctx.userAgent);
});

async function sendToMacDM(url, maxHeight, referrer, cookies, userAgent, hints) {
  try {
    const body = { url };
    if (maxHeight) body.maxHeight = maxHeight;
    if (referrer) body.referrer = referrer;
    if (cookies) body.cookies = cookies;
    if (userAgent) body.userAgent = userAgent;
    if (hints?.filename) body.filename = hints.filename;
    if (hints?.mime) body.mime = hints.mime;
    // video intent (overlay pill, popup page rows): the link is a video page
    // or media stream, so macdm must route it through yt-dlp even when the
    // host isn't on its known list — otherwise a page URL would be saved as
    // an HTML file
    if (hints?.video) body.forceVideo = true;
    const res = await fetch(MACDM_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    return res.ok;
  } catch {
    return false;
  }
}

/** Asks the macdm app for a video page's title + available qualities. */
async function lookupInfo(url) {
  try {
    const ctx = await browserContext(url);
    const res = await fetch(MACDM_INFO, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url, cookies: ctx.cookies, userAgent: ctx.userAgent }),
    });
    return res.ok ? await res.json() : null;
  } catch {
    return null;
  }
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg?.type === "macdm-add" && msg.url) {
    (async () => {
      const ctx = await browserContext(msg.url);
      const ok = await sendToMacDM(msg.url, msg.maxHeight, msg.referrer,
                                   ctx.cookies, ctx.userAgent, { video: msg.video });
      sendResponse({ ok });
    })();
    return true;
  }
  if (msg?.type === "macdm-scan" && msg.tabId != null) {
    chrome.tabs.get(msg.tabId, tab => {
      if (tab?.url) {
        autoScan(msg.tabId, tab.url, tab.title).then(() => sendResponse(scans.get(msg.tabId)));
      } else {
        sendResponse({ url: null, title: "", videos: [], isVideoSite: false });
      }
    });
    return true;
  }
  if (msg?.type === "macdm-streams") {
    // HLS/DASH playlists the webRequest observer caught on this tab — the
    // overlay menu offers them for blob players (sender.tab is this tab)
    sendResponse({ streams: streamEntries(sender.tab?.id ?? -1) });
    return;
  }
  if (msg?.type === "macdm-info" && msg.url) {
    lookupInfo(msg.url).then(sendResponse);
    return true;
  }
  if (msg?.type === "macdm-intercept-get") {
    interceptEnabled().then(enabled => sendResponse({ enabled }));
    return true;
  }
  if (msg?.type === "macdm-intercept-set") {
    chrome.storage.local.set({ [INTERCEPT_KEY]: !!msg.enabled }, () =>
      sendResponse({ enabled: !!msg.enabled }));
    return true;
  }
});
