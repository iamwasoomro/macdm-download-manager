// IDM-style overlay: a floating "Download this video" pill pinned to every
// sizeable <video> player. Runs in every frame; each frame decorates its own
// videos (players inside iframes included).
//  - direct http(s) src -> the file URL is sent to macdm
//  - blob:/data:/no src -> the PAGE url is sent (macdm resolves it via yt-dlp),
//    unless the background captured HLS/DASH playlists for this tab, in which
//    case a small menu offers those first (IDM's "multiple downloads found").

(() => {
  const MIN_W = 200;   // skip players smaller than this (ads, trackers, pixels)
  const MIN_H = 140;
  const SWEEP_MS = 2500;

  const overlays = new Map();  // <video> -> {root, pill, menu, ro}
  const dismissed = new WeakSet();

  function videoUrl(v) {
    const src = v.currentSrc || v.src || "";
    return /^https?:/.test(src) ? src : "";
  }

  function heightLabel(v) {
    const h = v.videoHeight;
    if (!h) return "";
    if (h >= 2160) return "4K";
    return `${h}p`;
  }

  function defaultLabel(v) {
    const q = heightLabel(v);
    return "⬇ Download this video" + (q ? " · " + q : "");
  }

  function visibleRect(v) {
    const r = v.getBoundingClientRect();
    if (r.width < MIN_W || r.height < MIN_H) return null;
    const st = getComputedStyle(v);
    if (st.display === "none" || st.visibility === "hidden" || st.opacity === "0") return null;
    return r;
  }

  // ---- pill states ---------------------------------------------------------

  function setPill(pill, text, state) {
    pill.textContent = text;
    pill.className = "macdm-pill macdm-" + state;
    pill.dataset.state = state;
  }

  function resetPill(v, pill) {
    setPill(pill, defaultLabel(v), "idle");
  }

  async function send(url, v, pill) {
    setPill(pill, "Sending…", "busy");
    let res = null;
    try { res = await chrome.runtime.sendMessage({ type: "macdm-add", url, referrer: location.href }); }
    catch { /* app/extension race */ }
    if (res?.ok) {
      setPill(pill, "Sent to macdm ✓", "ok");
      setTimeout(() => resetPill(v, pill), 2500);
    } else {
      setPill(pill, "macdm app is not running", "err");
      setTimeout(() => resetPill(v, pill), 3000);
    }
  }

  // ---- stream menu (blob players with captured HLS/DASH playlists) ---------

  function closeAllMenus() {
    for (const st of overlays.values()) st.menu.classList.remove("macdm-open");
  }

  function openMenu(st, streams) {
    const menu = st.menu;
    menu.textContent = "";
    for (const s of streams) {
      const b = document.createElement("button");
      b.className = "macdm-row";
      b.type = "button";
      const name = document.createElement("span");
      name.textContent = s.name;
      name.title = s.src;
      const kind = document.createElement("em");
      kind.textContent = s.kind || "stream";
      b.append(name, kind);
      b.onclick = e => { e.stopPropagation(); closeAllMenus(); send(s.src, st.video, st.pill); };
      menu.append(b);
    }
    const page = document.createElement("button");
    page.className = "macdm-row";
    page.type = "button";
    const name = document.createElement("span");
    name.textContent = "This page · resolved by yt-dlp";
    const kind = document.createElement("em");
    kind.textContent = "PAGE";
    page.append(name, kind);
    page.onclick = e => { e.stopPropagation(); closeAllMenus(); send(location.href, st.video, st.pill); };
    menu.append(page);
    menu.classList.add("macdm-open");
  }

  async function onPillClick(v, st) {
    if (st.pill.dataset.state !== "idle") return;
    if (st.menu.classList.contains("macdm-open")) { closeAllMenus(); return; }
    const direct = videoUrl(v);
    if (direct) { send(direct, v, st.pill); return; }
    // blob player: prefer the playlists the background caught on this tab
    let streams = [];
    try {
      const res = await chrome.runtime.sendMessage({ type: "macdm-streams" });
      streams = res?.streams || [];
    } catch { /* fall through to the page url */ }
    if (streams.length) { openMenu(st, streams); return; }
    send(location.href, v, st.pill);
  }

  // ---- overlay lifecycle ---------------------------------------------------

  function position(v, st) {
    const r = visibleRect(v);
    const onScreen = r && r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth;
    if (!onScreen) { st.root.style.display = "none"; return; }
    st.root.style.display = "block";
    // anchor the bar's RIGHT edge to the player's top-right corner
    const x = Math.min(Math.max(r.left + 6, r.right - 8), innerWidth - 8);
    const y = Math.min(Math.max(r.top + 8, 6), Math.max(innerHeight - 44, 6));
    st.root.style.left = x + "px";
    st.root.style.top = y + "px";
  }

  function positionAll() { for (const [v, st] of overlays) position(v, st); }

  function destroy(v) {
    const st = overlays.get(v);
    if (!st) return;
    st.ro.disconnect();
    st.root.remove();
    overlays.delete(v);
  }

  function ensure(v) {
    if (overlays.has(v) || dismissed.has(v)) return;
    const root = document.createElement("div");
    root.className = "macdm-ov";
    const bar = document.createElement("div");
    bar.className = "macdm-bar";
    const pill = document.createElement("button");
    pill.type = "button";
    resetPill(v, pill);
    const close = document.createElement("button");
    close.type = "button";
    close.className = "macdm-close";
    close.textContent = "×";
    close.title = "Hide the macdm button";
    bar.append(pill, close);
    const menu = document.createElement("div");
    menu.className = "macdm-menu";
    root.append(bar, menu);

    const st = { video: v, root, pill, menu, ro: null };
    pill.addEventListener("click", e => { e.preventDefault(); e.stopPropagation(); onPillClick(v, st); });
    close.addEventListener("click", e => { e.preventDefault(); e.stopPropagation(); dismissed.add(v); destroy(v); });
    st.ro = new ResizeObserver(() => position(v, st));
    st.ro.observe(v);

    (document.body || document.documentElement).append(root);
    overlays.set(v, st);
    position(v, st);
  }

  /** document + open shadow roots (custom-element players keep their <video> there). */
  function collectVideos() {
    const out = [];
    const walk = root => {
      if (!root?.querySelectorAll) return;
      root.querySelectorAll("video").forEach(v => out.push(v));
      root.querySelectorAll("*").forEach(el => { if (el.shadowRoot) walk(el.shadowRoot); });
    };
    walk(document);
    return out;
  }

  function sweep() {
    // tiny frames are ad slots / trackers, not player embeds
    if (innerWidth < MIN_W || innerHeight < MIN_H) return;
    for (const [v, st] of [...overlays]) {
      if (!v.isConnected) { destroy(v); continue; }
      if (st.pill.dataset.state === "idle") {
        const want = defaultLabel(v);
        if (st.pill.textContent !== want) st.pill.textContent = want;
        st.pill.title = videoUrl(v) || location.href + " (resolved by yt-dlp)";
      }
    }
    collectVideos().forEach(ensure);
    positionAll();
  }

  addEventListener("scroll", () => { closeAllMenus(); positionAll(); }, { capture: true, passive: true });
  addEventListener("resize", positionAll);
  addEventListener("fullscreenchange", positionAll);
  document.addEventListener("click", e => {
    if (!e.target.closest?.(".macdm-ov")) closeAllMenus();
  }, true);
  document.addEventListener("keydown", e => { if (e.key === "Escape") closeAllMenus(); });

  sweep();
  setInterval(sweep, SWEEP_MS);
})();
