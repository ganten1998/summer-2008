/* volume-control.js
 *
 * Floating volume control for Summer 2008. Sits in the bottom-right of
 * every page (dashboard, mirror, inline player), shares ONE persisted
 * value across every origin via the Swift-backed prefs endpoint at
 * `agd://runtime/__prefs__/volume`, and applies to every <ruffle-player>
 * on the page — both the ones already in the DOM and any that get added
 * later by Ruffle's polyfill or our SWFObject shim.
 *
 * Scope note: this controls INLINE Ruffle audio only. The external
 * Flash Player.app and Wine/Director projector windows run in separate
 * processes; they're independent of WKWebView and can't be reached from
 * here. Users adjust those via the projector's own context menu or
 * macOS's per-app audio output controls.
 */
(function () {
  "use strict";
  if (window.__AGD_VOLUME_CONTROL__) return;
  window.__AGD_VOLUME_CONTROL__ = true;

  var PREFS_URL = "agd://runtime/__prefs__/volume";
  var LOCAL_CACHE_KEY = "agd:volume:cache";  // mirrors the server value for instant-render
  // Default is muted. A 2008 American Girl game shouldn't blast audio
  // on launch — users with no prior preference get silence, which they
  // can lift via the bottom-right slider. Anyone who's set a volume
  // previously has their value restored through the prefs endpoint +
  // localStorage cache.
  var DEFAULT_VOLUME = 0;

  // ---------------------------------------------------------------- prefs IO

  function readLocalCache() {
    try {
      var raw = localStorage.getItem(LOCAL_CACHE_KEY);
      if (raw == null) return null;
      var v = parseFloat(raw);
      if (isFinite(v) && v >= 0 && v <= 1) return v;
    } catch (e) {}
    return null;
  }

  function writeLocalCache(v) {
    try { localStorage.setItem(LOCAL_CACHE_KEY, String(v)); } catch (e) {}
  }

  // Server (cross-origin truth)
  function readServerVolume() {
    return fetch(PREFS_URL, { cache: "no-store" })
      .then(function (r) { return r.json(); })
      .then(function (j) {
        if (j && j.value != null) {
          var v = parseFloat(j.value);
          if (isFinite(v) && v >= 0 && v <= 1) return v;
        }
        return null;
      })
      .catch(function () { return null; });
  }

  var writeServerInflight = null;
  var writeServerPending = null;
  function writeServerVolume(v) {
    // Coalesce: if a write is in-flight, just stash the latest desired
    // value and fire it when the in-flight one completes.
    if (writeServerInflight) {
      writeServerPending = v;
      return;
    }
    writeServerInflight = fetch(PREFS_URL, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(v),
    }).catch(function () {}).then(function () {
      writeServerInflight = null;
      if (writeServerPending != null) {
        var pending = writeServerPending;
        writeServerPending = null;
        writeServerVolume(pending);
      }
    });
  }

  // ---------------------------------------------------------------- CSS

  var STYLE = [
    ".agd-volume{",
    "  position:fixed;right:20px;bottom:20px;z-index:99999;",
    "  display:flex;align-items:center;gap:10px;",
    "  background:linear-gradient(135deg,rgba(124,12,31,0.94) 0%,rgba(166,25,46,0.94) 100%);",
    "  -webkit-backdrop-filter:blur(14px);backdrop-filter:blur(14px);",
    "  color:#FBF6EB;font-family:-apple-system,'SF Pro Text','Helvetica Neue',sans-serif;",
    "  padding:7px 14px 7px 11px;border-radius:999px;",
    /* Hard-coded width matches the flash pill's pixel-perfect bounds. */
    "  width:65px;overflow:hidden;box-sizing:border-box;",
    "  box-shadow:0 8px 24px rgba(124,12,31,0.30),0 2px 4px rgba(124,12,31,0.16);",
    "  border:1px solid rgba(255,246,229,0.22);",
    "  opacity:.55;",
    "  transition:opacity .25s ease,padding-right .25s ease,width .25s ease;",
    "  user-select:none;-webkit-user-select:none;",
    "}",
    ".agd-volume:hover,.agd-volume.is-open{width:248px;}",
    ".agd-volume:hover,.agd-volume.is-open{opacity:1;padding-right:18px;}",
    ".agd-volume button.agd-vol-icon{",
    "  background:none;border:0;color:#FBF6EB;cursor:pointer;",
    "  padding:0;display:flex;align-items:center;justify-content:center;",
    "  width:20px;height:20px;",
    "}",
    ".agd-volume input.agd-vol-slider{",
    "  -webkit-appearance:none;appearance:none;",
    "  width:0;opacity:0;height:4px;",
    "  background:rgba(255,246,229,0.30);border-radius:999px;outline:none;",
    "  margin:0;",
    "  transition:width .22s ease,opacity .22s ease;",
    "}",
    /* Slider grows to 158px when expanded — picked so that the total
       extended pill width (icon+gap+slider+gap+pct = 20+10+158+10+26 =
       224) matches the Flash pill's extended label width (224). The
       two pills now have IDENTICAL extended bounds when both open. */
    ".agd-volume:hover input.agd-vol-slider,",
    ".agd-volume.is-open input.agd-vol-slider{width:158px;opacity:1;}",
    ".agd-volume input.agd-vol-slider::-webkit-slider-thumb{",
    "  -webkit-appearance:none;appearance:none;",
    "  width:14px;height:14px;border-radius:50%;",
    "  background:#FBF6EB;border:0;cursor:pointer;",
    "  box-shadow:0 1px 3px rgba(0,0,0,0.22);",
    "  transition:transform .15s ease;",
    "}",
    ".agd-volume input.agd-vol-slider::-webkit-slider-thumb:hover{transform:scale(1.18);}",
    ".agd-volume .agd-vol-pct{",
    "  font-size:10px;letter-spacing:.12em;text-transform:uppercase;",
    "  font-weight:600;color:rgba(255,246,229,0.85);",
    "  width:0;opacity:0;overflow:hidden;white-space:nowrap;",
    "  transition:width .22s ease,opacity .22s ease;",
    "}",
    ".agd-volume:hover .agd-vol-pct,",
    ".agd-volume.is-open .agd-vol-pct{width:26px;opacity:1;}",
    /* Flash projector pill stacks above the volume pill at bottom:64px;
       its position is defined by flash-bridge.js directly (matching the
       volume pill's exact size + gradient so the two read as a single
       vertical pill stack). */
  ].join("");

  function injectStyle() {
    if (document.getElementById("agd-volume-css")) return;
    var s = document.createElement("style");
    s.id = "agd-volume-css";
    s.textContent = STYLE;
    (document.head || document.documentElement).appendChild(s);
  }

  // ---------------------------------------------------------------- icon

  function iconState(v) {
    if (v <= 0.005) return "mute";
    if (v < 0.34) return "low";
    if (v < 0.67) return "med";
    return "high";
  }
  function iconSVG(v) {
    var st = iconState(v);
    var s = '<svg viewBox="0 0 22 20" width="20" height="20" aria-hidden="true">';
    s += '<path d="M3 7 H7 L11 3.5 V16.5 L7 13 H3 Z" fill="currentColor"/>';
    if (st === "mute") {
      s += '<line x1="14" y1="6" x2="20" y2="14" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>';
      s += '<line x1="20" y1="6" x2="14" y2="14" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>';
    } else {
      s += '<path d="M13 7c1.3 1 1.7 1.8 1.7 3s-.4 2-1.7 3" stroke="currentColor" stroke-width="1.5" fill="none" stroke-linecap="round"/>';
      if (st === "med" || st === "high") {
        s += '<path d="M15.4 5c2 1.5 2.7 3 2.7 5s-.7 3.5-2.7 5" stroke="currentColor" stroke-width="1.5" fill="none" stroke-linecap="round"/>';
      }
      if (st === "high") {
        s += '<path d="M17.8 3c2.7 2 3.5 3.7 3.5 7s-.8 5-3.5 7" stroke="currentColor" stroke-width="1.5" fill="none" stroke-linecap="round"/>';
      }
    }
    s += '</svg>';
    return s;
  }

  // ---------------------------------------------------------------- Ruffle apply

  /* Push the current volume into Ruffle. Setting just `player.volume`
     no-ops when `this.instance` (the WASM player) isn't ready yet —
     happens when we set it during initial load. We also have to write
     `volumeSettings.{volume,isMuted}` directly, because that's the state
     Ruffle resyncs from after load completes and on its own UI changes.
     Scale: Ruffle's public setter is 0-1; volumeSettings.volume is 0-100.
  */
  function applyToPlayer(p, v) {
    try {
      var muted = v <= 0.005;
      // Internal settings — survives load() and Ruffle's own UI sync.
      if (p.volumeSettings) {
        p.volumeSettings.volume  = v * 100;
        p.volumeSettings.isMuted = muted;
      }
      // Live instance — only present after the SWF/AVM machine has loaded.
      if (p.instance && typeof p.instance.set_volume === "function") {
        p.instance.set_volume(muted ? 0 : v);
      } else if ("volume" in p) {
        // Best-effort: setter no-ops pre-load but does the right thing
        // post-load if loadedmetadata fires before we get re-called.
        p.volume = muted ? 0 : v;
      }
    } catch (e) {}
  }

  var watchedPlayers = new WeakSet();
  function watchPlayer(p, getV) {
    if (watchedPlayers.has(p)) return;
    watchedPlayers.add(p);
    // Re-apply once Ruffle finishes booting the SWF — at that point
    // `p.instance` exists, so the setter takes effect for real.
    ["loadedmetadata", "loadeddata", "loadcomplete"].forEach(function (ev) {
      p.addEventListener(ev, function () { applyToPlayer(p, getV()); });
    });
  }

  // Apply current volume to every same-origin iframe's audio system too.
  // Pages like the ecard wizard render their preview SWF inside an
  // iframe (each iframe gets its own Ruffle WASM instance) — without
  // this, dragging the parent's slider wouldn't reach the iframe's
  // audio context and ecard previews would play at config-default
  // volume regardless of the slider.
  function dispatchToIframes(v) {
    var muted = v <= 0.005;
    var frames = document.querySelectorAll("iframe");
    for (var i = 0; i < frames.length; i++) {
      try {
        var w = frames[i].contentWindow;
        if (!w) continue;
        if (typeof w.__AGD_AUDIO_GAIN__ === "function") {
          try { w.__AGD_AUDIO_GAIN__(muted ? 0 : v); } catch (e) {}
        }
        if (typeof w.__AGD_AUDIO_MUTE__ === "function") {
          try { w.__AGD_AUDIO_MUTE__(muted); } catch (e) {}
        }
        // Also poke any Ruffle players inside the iframe so volumeSettings
        // gets set (covers the case where Ruffle is mid-load and the WASM
        // hasn't created its AudioContext yet — but the player element
        // exists).
        try {
          var doc = frames[i].contentDocument;
          if (doc) {
            var ps = doc.querySelectorAll("ruffle-player,ruffle-object,ruffle-embed");
            for (var j = 0; j < ps.length; j++) applyToPlayer(ps[j], v);
          }
        } catch (e) {}
      } catch (e) {}
    }
  }

  // HTML5 <video> (the movie-hub trailers): follow the same global
  // slider. Their native volume/mute UI is hidden via injected CSS (see
  // hideNativeVideoVolumeUI) so the bottom-right pill is the ONLY volume
  // control — and it defaults to 0, so autoplaying trailers start silent.
  function applyToVideo(el, v) {
    try {
      var muted = v <= 0.005;
      el.volume = muted ? 0 : v;
      el.muted = muted;
    } catch (e) {}
  }
  function hideNativeVideoVolumeUI() {
    if (document.getElementById("agd-video-vol-css")) return;
    var s = document.createElement("style");
    s.id = "agd-video-vol-css";
    s.textContent =
      "video::-webkit-media-controls-mute-button," +
      "video::-webkit-media-controls-volume-slider," +
      "video::-webkit-media-controls-volume-control-container" +
      "{display:none!important;width:0!important;}";
    (document.head || document.documentElement).appendChild(s);
  }

  function applyToAllRufflePlayers(v) {
    var muted = v <= 0.005;
    // Update Ruffle's default config so any future players inherit.
    try {
      window.RufflePlayer = window.RufflePlayer || {};
      window.RufflePlayer.config = Object.assign(window.RufflePlayer.config || {}, {
        volume: muted ? 0 : v,
        muted:  muted,
      });
    } catch (e) {}
    var nodes = document.querySelectorAll("ruffle-player,ruffle-object,ruffle-embed");
    for (var i = 0; i < nodes.length; i++) applyToPlayer(nodes[i], v);

    hideNativeVideoVolumeUI();
    var vids = document.querySelectorAll("video");
    for (var k = 0; k < vids.length; k++) applyToVideo(vids[k], v);

    // Proportional volume: set per-context master gain. The hijacked
    // AudioNode.connect in ruffle-boot.js routes every node connecting
    // to ctx.destination through this gain, so this actually controls
    // the volume linearly (slider at 50% = half output).
    if (typeof window.__AGD_AUDIO_GAIN__ === "function") {
      try { window.__AGD_AUDIO_GAIN__(muted ? 0 : v); } catch (e) {}
    }
    // Hard mute: suspend the AudioContext entirely. Belt-and-braces
    // alongside the gain=0 above so audio is definitively dead at 0%.
    if (typeof window.__AGD_AUDIO_MUTE__ === "function") {
      try { window.__AGD_AUDIO_MUTE__(muted); } catch (e) {}
    }

    dispatchToIframes(v);
  }

  // ---------------------------------------------------------------- mount

  function ensureControl() {
    if (document.getElementById("agd-volume")) return;
    if (!document.body) {
      document.addEventListener("DOMContentLoaded", ensureControl, { once: true });
      return;
    }
    injectStyle();

    // Instant-paint with the local cache so the slider doesn't flicker
    // while we wait for the Swift backend round-trip.
    var v = readLocalCache();
    if (v == null) v = DEFAULT_VOLUME;
    var lastNonZero = v > 0 ? v : DEFAULT_VOLUME;

    var wrap = document.createElement("div");
    wrap.id = "agd-volume";
    wrap.className = "agd-volume";
    wrap.setAttribute("role", "group");
    wrap.setAttribute("aria-label", "Volume");

    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "agd-vol-icon";
    btn.title = "Mute / unmute (click)";
    btn.setAttribute("aria-label", "Mute toggle");
    btn.innerHTML = iconSVG(v);

    var slider = document.createElement("input");
    slider.type = "range";
    slider.min = "0";
    slider.max = "1";
    slider.step = "0.01";
    slider.value = String(v);
    slider.className = "agd-vol-slider";
    slider.title = "Volume";
    slider.setAttribute("aria-label", "Volume level");

    var pct = document.createElement("span");
    pct.className = "agd-vol-pct";
    pct.textContent = Math.round(v * 100) + "%";

    function setVolume(newV, opts) {
      opts = opts || {};
      v = Math.max(0, Math.min(1, isFinite(newV) ? newV : 0));
      if (v > 0) lastNonZero = v;
      slider.value = String(v);
      btn.innerHTML = iconSVG(v);
      pct.textContent = Math.round(v * 100) + "%";
      writeLocalCache(v);
      if (opts.persist !== false) writeServerVolume(v);
      applyToAllRufflePlayers(v);
      if (opts.flash) {
        wrap.classList.add("is-open");
        clearTimeout(setVolume._closeT);
        setVolume._closeT = setTimeout(function () { wrap.classList.remove("is-open"); }, 1400);
      }
    }

    btn.addEventListener("click", function () {
      if (v > 0.005) setVolume(0, { flash: true });
      else setVolume(lastNonZero, { flash: true });
    });

    slider.addEventListener("input", function () {
      setVolume(parseFloat(slider.value), { flash: true });
    });

    // Live-sync when another open page updates the prefs file (best-effort:
    // localStorage events fire across same-origin tabs only, so the true
    // cross-origin sync happens via the Swift backend on every navigation).
    window.addEventListener("storage", function (e) {
      if (e.key === LOCAL_CACHE_KEY && e.newValue != null) {
        var nv = parseFloat(e.newValue);
        if (isFinite(nv) && Math.abs(nv - v) > 0.001) {
          setVolume(nv, { persist: false });
        }
      }
    });

    wrap.appendChild(btn);
    wrap.appendChild(slider);
    wrap.appendChild(pct);
    document.body.appendChild(wrap);

    // First paint applied locally; now sync from the cross-origin truth.
    applyToAllRufflePlayers(v);
    readServerVolume().then(function (serverV) {
      if (serverV != null && Math.abs(serverV - v) > 0.001) {
        setVolume(serverV, { persist: false });
      }
    });

    // Re-apply to any new <ruffle-player> elements as they arrive, and
    // wire their loadedmetadata so volume sticks once the SWF boots.
    var watchedFrames = new WeakSet();
    function rescan() {
      var nodes = document.querySelectorAll("ruffle-player,ruffle-object,ruffle-embed");
      for (var i = 0; i < nodes.length; i++) {
        applyToPlayer(nodes[i], v);
        watchPlayer(nodes[i], function () { return v; });
      }
      hideNativeVideoVolumeUI();
      var vids = document.querySelectorAll("video");
      for (var n = 0; n < vids.length; n++) applyToVideo(vids[n], v);
      // New iframes: hook their load event so the iframe's Ruffle/audio
      // gets the current slider value the moment its scripts initialize.
      var frames = document.querySelectorAll("iframe");
      for (var k = 0; k < frames.length; k++) {
        var f = frames[k];
        if (watchedFrames.has(f)) continue;
        watchedFrames.add(f);
        f.addEventListener("load", function () { dispatchToIframes(v); });
        // Also poke immediately in case the iframe is already loaded.
        try { dispatchToIframes(v); } catch (e) {}
      }
    }
    rescan();
    // Debounce rescan — busy pages (homepage hero SWF, magazine layouts)
    // mutate the DOM in flurries; running the full audio-dispatch chain
    // on each mutation thrashes Ruffle's startup.
    var rescanT = 0;
    var mo = new MutationObserver(function () {
      clearTimeout(rescanT);
      rescanT = setTimeout(rescan, 120);
    });
    mo.observe(document.body, { childList: true, subtree: true });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", ensureControl, { once: true });
  } else {
    ensureControl();
  }
})();
