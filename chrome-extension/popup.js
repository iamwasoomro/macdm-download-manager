const $ = id => document.getElementById(id);
const status = (msg, err = false) => {
  $("status").textContent = msg;
  $("status").className = err ? "err" : "";
};

let pageUrl = null; // current tab URL, sent as the download's referrer

async function addURL(url, maxHeight, video) {
  if (!url) return;
  const res = await chrome.runtime.sendMessage({ type: "macdm-add", url, maxHeight, referrer: pageUrl, video: video !== false });
  status(res?.ok ? "Sent to macdm ✓" : "MacDM is not available. Open the app and try again.", !res?.ok);
}

// detected rows are always video intent; the manual URL field is not
$("add").onclick = () => addURL($("url").value.trim(), null, false);
$("url").addEventListener("keydown", e => { if (e.key === "Enter") addURL(e.target.value.trim(), null, false); });
// a different URL invalidates the detected list — don't leave stale entries
$("url").addEventListener("input", e => {
  if (e.target.value.trim() !== pageUrl) {
    $("found").innerHTML = "";
    status("");
  }
});

function qualityLabel(h) {
  if (!h) return "quality n/a";
  if (h >= 2160) return "4K (2160p)";
  if (h >= 1440) return "1440p";
  return `${h}p`;
}

function shortName(name, max = 46) {
  let clean = (name || "").split("?")[0];
  try { clean = decodeURIComponent(clean); } catch {}
  return clean.length > max ? clean.slice(0, max - 1) + "…" : clean;
}

function row(url, name, quality, maxHeight, referrer) {
  const li = document.createElement("li");
  const label = document.createElement("div");
  label.className = "entry";
  const title = document.createElement("span");
  title.className = "name";
  title.textContent = name;
  title.title = url;
  const q = document.createElement("span");
  q.className = "quality";
  q.textContent = quality;
  label.append(title, q);
  const btn = document.createElement("button");
  btn.textContent = "Download";
  // every listed row is a video/stream/page link — flag video intent
  btn.onclick = e => { e.preventDefault(); addURL(url, maxHeight ?? null, true); };
  li.append(label, btn);
  return li;
}

/** Runs automatically when the popup opens — no detect button needed. */
async function populate() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id) { status("No active tab"); return; }
  const scan = await chrome.runtime.sendMessage({ type: "macdm-scan", tabId: tab.id });
  const list = $("found");
  list.innerHTML = "";
  if (!scan?.url) { status("Cannot scan this page"); return; }
  pageUrl = scan.url;

  const entries = [];

  if (scan.isVideoSite) {
    status("Contacting macdm for video info…");
    const info = await chrome.runtime.sendMessage({ type: "macdm-info", url: scan.url });
    const name = shortName(info?.title || scan.title);
    if (info?.heights?.length) {
      for (const h of info.heights) {
        entries.push(row(scan.url, name, qualityLabel(h), h, scan.url));
      }
    } else {
      entries.push(row(scan.url, name, "best available", null, scan.url));
    }
  }

  for (const v of scan.videos || []) {
    entries.push(row(v.src, shortName(v.name), qualityLabel(v.height)));
  }
  // HLS/DASH playlists caught on the tab's network — macdm downloads them
  // through yt-dlp and remuxes the result to mp4.
  for (const s of scan.streams || []) {
    entries.push(row(s.src, shortName(s.name), s.kind || "stream", null, scan.url));
  }

  if (!entries.length) {
    if (scan.blobVideos > 0) {
      status("In-page blob stream can't be fetched directly — the page link below goes through yt-dlp");
    } else {
      status("No videos detected on this page");
    }
    // still allow sending the page itself to the app
    entries.push(row(scan.url, shortName(scan.title), "send page", null, scan.url));
  } else {
    status(`${entries.length} item(s) detected — pick a quality and download`);
  }
  entries.forEach(e => list.append(e));
}

populate();

// interception toggle state
chrome.runtime.sendMessage({ type: "macdm-intercept-get" }).then(res => {
  $("intercept").checked = !!res?.enabled;
});
$("intercept").addEventListener("change", e => {
  chrome.runtime.sendMessage({ type: "macdm-intercept-set", enabled: e.target.checked });
});
