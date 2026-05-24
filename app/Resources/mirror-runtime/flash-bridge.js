/* flash-bridge.js
 *
 * Bridges the 2008-era American Girl site's Flash machinery to Ruffle so
 * that Flash content plays INLINE in WKWebView (matching the original
 * in-browser experience), with a graceful "Open in Flash Player" fallback
 * when Ruffle can't render a particular SWF.
 *
 * Loaded BEFORE the mirrored page's own scripts (the patcher injects this
 * tag at the top of <head>) so our SWFObject shim is in place before any
 * inline `new SWFObject(...)` call runs.
 *
 * What we do:
 *   1. Shim SWFObject 1.x (`new SWFObject(...)`) and SWFObject 2.x
 *      (`swfobject.embedSWF`) so that constructing/embedding a Flash movie
 *      builds a <ruffle-player> element instead.
 *   2. Lock our shimmed globals with Object.defineProperty so the
 *      mirrored swfobject.js (which runs *after* us) cannot displace them.
 *   3. After DOM ready, run a safety-net pass that converts any leftover
 *      <object>/<embed> Flash tags Ruffle's own polyfill missed.
 *   4. Attach "loaderror" listeners to every <ruffle-player> we create so
 *      a broken SWF gracefully falls back to a crimson stub that launches
 *      the bundled standalone Flash projector.
 */
(function () {
  "use strict";

  if (window.__AGD_FLASH_BRIDGE__) return;
  window.__AGD_FLASH_BRIDGE__ = true;

  // After we define buildStub() below, this gets pointed at it so other
  // scripts on the page (notably runtime/player.html) can render the same
  // "Open in Flash Player" stub when Ruffle errors out.
  window.__AGD_BUILD_STUB__ = function () { return null; };

  // SWFs we know no archive captured — Wayback CDX deep walk, host swap,
  // Memento aggregator, archive.today, and the live AG CDN all returned
  // empty during the recovery sweep. Listed at
  // build/cdx/exhaustive_unrecovered_ecards.txt in the repo. When one of
  // these is referenced by a page, makeRuffle short-circuits to the
  // sepia "Lost to time" stub — a deliberate preservation note rather
  // than the crimson "Open in Flash Player" tile, which promises action
  // the host can't deliver.
  var LOST_SWFS = new Set([
    "2008_Spring_Doodle.swf", "ChristmasStar2007.swf", "Hanukkah2007.swf",
    "HappyFourth.swf", "Julie_birthday.swf", "Mia_GOTY08.swf",
    "ag_VdayCutOut.swf", "ag_dove.swf", "ag_ecard_birthday.swf",
    "ag_ecard_winter.swf", "ag_fday06_doodle.swf", "ag_perfbead.swf",
    "agc_bday_kit.swf", "agc_kit_banister.swf", "agc_molly_bday.swf",
    "agl_congrats_ecard.swf", "agtravel_London.swf",
    "coco_lic_easter_ecard.swf", "ec_ag_hween.swf", "ec_ag_tgiving.swf",
    "ec_coccovtine.swf", "ec_coco_halloween.swf", "ec_coco_holiday04.swf",
    "ec_coco_summer06.swf", "goty_lindsey.swf", "goty_marisol.swf"
  ]);
  function isLostSWF(url) {
    try {
      var u = new URL(url, document.baseURI);
      var leaf = u.pathname.split("/").pop();
      return LOST_SWFS.has(leaf);
    } catch (e) { return false; }
  }

  // BFCache reload: WKWebView preserves DOM state when the user navigates
  // back to a previously-visited mirror page, but Ruffle's WASM module is
  // GC'd between visits. The restored <ruffle-player> elements end up
  // dead, and any Flash-detection alt-content the original AG page baked
  // into the DOM ("you need the Flash plug-in") is what the user sees.
  // Forcing a reload on bfcache restore makes the scripts re-run cleanly.
  window.addEventListener("pageshow", function (e) {
    if (e.persisted) location.reload();
  });

  // -------- DEBUG: when URL has #agddebug, mirror console into an overlay
  var DEBUG = /agddebug/.test(location.hash || "");
  var dbgEl = null;
  function dbg() {
    if (!DEBUG) return;
    if (!dbgEl) {
      dbgEl = document.createElement("pre");
      dbgEl.id = "agd-dbg";
      dbgEl.style.cssText = "position:fixed;bottom:0;left:0;right:0;max-height:35vh;overflow:auto;margin:0;padding:8px;background:rgba(0,0,0,0.85);color:#FBF6EB;font:11px Menlo,monospace;z-index:99999;white-space:pre-wrap;";
      (document.body || document.documentElement).appendChild(dbgEl);
    }
    var line = Array.prototype.slice.call(arguments).map(function (a) {
      try { return typeof a === "string" ? a : JSON.stringify(a); }
      catch (e) { return String(a); }
    }).join(" ");
    dbgEl.textContent += line + "\n";
    dbgEl.scrollTop = dbgEl.scrollHeight;
  }
  if (DEBUG) {
    ["log","warn","error","info"].forEach(function (lvl) {
      var orig = console[lvl];
      console[lvl] = function () { dbg.apply(null, ["[" + lvl + "]"].concat(Array.prototype.slice.call(arguments))); orig && orig.apply(console, arguments); };
    });
    window.addEventListener("error", function (e) { dbg("[onerror]", e.message, "@", e.filename + ":" + e.lineno); });
    window.addEventListener("unhandledrejection", function (e) { dbg("[reject]", String(e.reason)); });
    // Re-attach overlay after body exists
    document.addEventListener("DOMContentLoaded", function () {
      if (dbgEl && dbgEl.parentNode !== document.body) {
        document.body.appendChild(dbgEl);
      }
    });
  }

  // ----------------------------------------------------------- CSS
  var STYLE = [
    /* Tame Ruffle's default chrome so embeds blend with the AG cream page */
    "ruffle-player, ruffle-object, ruffle-embed{",
    "  display:inline-block;background:#000;",
    "  vertical-align:top;line-height:0;",
    "}",
    /* Crimson "Click to Play" fallback used when Ruffle declines */
    ".agd-flash-stub{",
    "  display:inline-block;position:relative;",
    "  background:linear-gradient(135deg,#A6192E 0%,#7C0C1F 100%);",
    "  color:#FBF6EB;font-family:'Hoefler Text',Georgia,serif;",
    "  border-radius:10px;overflow:hidden;cursor:pointer;",
    "  box-shadow:0 12px 36px rgba(124,12,31,0.30),0 2px 4px rgba(124,12,31,0.20);",
    "  border:1px solid rgba(255,246,229,0.18);",
    "  text-align:center;vertical-align:top;text-decoration:none;",
    "}",
    ".agd-flash-stub:hover{filter:brightness(1.06);}",
    ".agd-flash-stub::before{",
    "  content:'';position:absolute;inset:0;",
    "  background:radial-gradient(ellipse at 70% 0%, rgba(255,228,178,0.18) 0%, transparent 60%);",
    "  pointer-events:none;",
    "}",
    ".agd-flash-stub .agd-inner{",
    "  position:relative;height:100%;width:100%;",
    "  display:flex;flex-direction:column;align-items:center;justify-content:center;",
    "  padding:18px 18px;gap:10px;box-sizing:border-box;",
    "}",
    ".agd-flash-stub .agd-title{",
    "  font-size:20px;font-style:italic;line-height:1.1;",
    "  text-shadow:0 1px 0 rgba(0,0,0,.18);",
    "}",
    ".agd-flash-stub .agd-pill{",
    "  display:inline-flex;align-items:center;gap:6px;",
    "  font-family:-apple-system,'SF Pro Text',sans-serif;",
    "  font-size:10px;letter-spacing:.18em;text-transform:uppercase;font-weight:600;",
    "  background:rgba(255,246,229,0.16);color:#FFF6E5;padding:5px 10px;border-radius:999px;",
    "}",
    ".agd-flash-stub.agd-small .agd-title{font-size:14px;}",
    ".agd-flash-stub.agd-tiny .agd-title{font-size:12px;}",
    ".agd-flash-stub.agd-tiny .agd-pill{display:none;}",
    /* Lost-to-time variant. Sepia/cocoa palette — visually distinct
       from crimson (which suggests clickable Flash) and indigo (DCR).
       No hover, no pill, not interactive — reads as a preservation
       note, not a call-to-action. Used for SWFs we know Wayback +
       Memento + archive.today + live CDN ALL failed to surface. */
    ".agd-flash-stub.agd-lost{",
    "  background:linear-gradient(135deg,#5A4A38 0%,#3A2E22 100%);",
    "  cursor:default;",
    "}",
    ".agd-flash-stub.agd-lost:hover{filter:none;}",
    ".agd-flash-stub.agd-lost::before{display:none;}",
    ".agd-flash-stub.agd-lost .agd-inner{pointer-events:none;gap:8px;}",
    ".agd-flash-stub.agd-lost .agd-title{",
    "  font:600 17px/1.2 -apple-system,'SF Pro Text','Segoe UI',sans-serif;",
    "  font-style:normal;color:#FBF6EB;letter-spacing:.01em;",
    "}",
    ".agd-flash-stub.agd-lost .agd-sub{",
    "  font:11px/1.45 -apple-system,'SF Pro Text','Segoe UI',sans-serif;",
    "  color:rgba(251,246,235,0.72);max-width:280px;text-align:center;",
    "}",
    ".agd-flash-stub.agd-small.agd-lost .agd-title{font-size:13px;}",
    ".agd-flash-stub.agd-tiny.agd-lost .agd-title{font-size:11px;}",
    ".agd-flash-stub.agd-tiny.agd-lost .agd-sub{display:none;}",
    /* Shockwave variant: same chassis as the Flash stub but indigo, with
       an honest "not currently playable" message — Adobe end-of-lifed the
       Shockwave Player in 2019 and Ruffle is Flash-only, so .dcr embeds
       have nowhere to go. Better to surface that than leave a blank box. */
    ".agd-flash-stub.agd-dcr{",
    "  background:linear-gradient(135deg,#3B3768 0%,#1F1B3C 100%);",
    "  cursor:default;",
    "}",
    /* DCR stub container: only the pill takes pointer events; the rest of
       the indigo card is decorative. */
    ".agd-flash-stub.agd-dcr .agd-inner{pointer-events:none;}",
    ".agd-flash-stub.agd-dcr .agd-title{pointer-events:none;}",
    ".agd-flash-stub.agd-dcr .agd-pill{",
    "  background:rgba(255,246,229,0.14);color:#FFF6E5;",
    "  pointer-events:auto;cursor:pointer;text-decoration:none;",
    "  transition:background .15s ease, transform .12s ease,",
    "             box-shadow .15s ease, color .15s ease,",
    "             border-color .15s ease;",
    "  border:1px solid rgba(255,246,229,0.22);",
    "  will-change:transform;",
    "}",
    ".agd-flash-stub.agd-dcr .agd-pill:hover{",
    "  background:rgba(255,246,229,0.28) !important;",
    "  color:#FFFFFF !important;",
    "  transform:translateY(-1px);",
    "  box-shadow:0 8px 20px rgba(0,0,0,0.40);",
    "  border-color:rgba(255,246,229,0.55) !important;",
    "}",
    ".agd-flash-stub.agd-dcr .agd-pill:active{",
    "  transform:translateY(0);",
    "  background:rgba(255,246,229,0.36) !important;",
    "}",
    /* Pixelly Director-style loading overlay — shown after the user clicks
       the pill (or when auto-launch fires). The 320×240 / 640×480 look of
       2008-era Director: chunky monospace font, gray gradient background,
       slow scanline marquee. Bottom-pinned status text. Disappears when
       the host shell calls the dismiss hook (game window shown). */
    ".agd-flash-stub.agd-dcr .agd-loading{",
    "  position:absolute;inset:0;display:none;align-items:center;",
    "  justify-content:center;flex-direction:column;gap:18px;",
    "  background:linear-gradient(180deg,#9a9aa8 0%,#5d5d6a 100%);",
    "  color:#1c1c25;",
    "  font-family:'Courier New','Andale Mono',monospace;",
    "  font-size:11px;letter-spacing:.18em;text-transform:uppercase;",
    "  text-shadow:1px 1px 0 rgba(255,255,255,0.25);",
    "  image-rendering:pixelated;",
    "}",
    /* When the user clicks Play, the embed area must instantly stop
       showing the idle title + pill text — Wine takes a beat to spawn
       and Director shows its own intro. Hide the inner content
       completely (visibility + display, not just opacity, so it can't
       peek through during the loading state). */
    ".agd-flash-stub.agd-dcr.is-loading .agd-loading{display:flex;}",
    ".agd-flash-stub.agd-dcr.is-loading .agd-inner{",
    "  visibility:hidden!important;opacity:0!important;",
    "  pointer-events:none!important;",
    "}",
    /* Once the projector is alive and overlaid on the embed area, the
       stub becomes a TRANSPARENT spacer — its only job is to occupy
       the right amount of layout space so page text below pushes down
       and doesn't get obscured. Any pixels where Wine's clamped window
       doesn't fully cover the stub (top title bar, 2px right/bottom)
       show the page's native bg through the transparent stub. */
    ".agd-flash-stub.agd-dcr.is-projector-running{",
    "  background:transparent!important;",
    "  box-shadow:none!important;border-color:transparent!important;",
    "}",
    ".agd-flash-stub.agd-dcr.is-projector-running .agd-inner{",
    "  display:none!important;",
    "}",
    ".agd-flash-stub.agd-dcr.is-projector-running .agd-loading{",
    "  display:none!important;",
    "}",
    ".agd-flash-stub.agd-dcr.is-projector-running::before{display:none!important;}",
    /* The familiar Director red-and-orange loading swatch. */
    ".agd-flash-stub.agd-dcr .agd-loading .agd-bar{",
    "  width:140px;height:14px;background:#3a3a45;",
    "  border:1px solid #1c1c25;",
    "  box-shadow:inset 1px 1px 0 rgba(0,0,0,.35);",
    "  position:relative;overflow:hidden;",
    "}",
    ".agd-flash-stub.agd-dcr .agd-loading .agd-bar::after{",
    "  content:'';position:absolute;inset:0;",
    "  width:40%;background:repeating-linear-gradient(",
    "    45deg,#F26C3B 0 8px,#D24A1F 8px 16px);",
    "  animation:agd-bar 1.4s linear infinite;",
    "}",
    "@keyframes agd-bar{0%{transform:translateX(-100%);}100%{transform:translateX(250%);}}",
    /* The little Director-logo-style square */
    ".agd-flash-stub.agd-dcr .agd-loading .agd-logo{",
    "  width:42px;height:42px;",
    "  background:",
    "    linear-gradient(135deg,#F26C3B 0%,#D24A1F 50%,#A02F0F 100%);",
    "  border:2px solid #1c1c25;",
    "  box-shadow:2px 2px 0 rgba(0,0,0,.30),",
    "             inset 1px 1px 0 rgba(255,255,255,.30);",
    "  image-rendering:pixelated;",
    "}",
    /* Floating "Open in Flash Projector" escape button — appears when a
       Ruffle player exists on the page so the user has a one-click way out
       when Ruffle misbehaves mid-game. */
    /* Sits DIRECTLY ABOVE the volume pill (which lives at bottom:20px,
       right:20px). Same width/padding/gradient/blur as the volume pill
       in its collapsed state; expands to the same dimensions as the
       expanded volume pill, surfacing the label. */
    ".agd-projector-fab{",
    "  position:fixed;right:20px;bottom:64px;z-index:99998;",
    "  display:flex;align-items:center;gap:10px;",
    "  background:linear-gradient(135deg,rgba(124,12,31,0.94) 0%,rgba(166,25,46,0.94) 100%);",
    "  -webkit-backdrop-filter:blur(14px);backdrop-filter:blur(14px);",
    "  color:#FBF6EB;font-family:-apple-system,'SF Pro Text','Helvetica Neue',sans-serif;",
    "  padding:7px 14px 7px 11px;border-radius:999px;",
    /* Hard-coded width — explicit collapsed and expanded sizes ensure
       PIXEL-IDENTICAL bounds with the volume pill regardless of any
       intrinsic-content rounding differences from min-width math. */
    "  width:65px;overflow:hidden;box-sizing:border-box;",
    "  box-shadow:0 8px 24px rgba(124,12,31,0.30),0 2px 4px rgba(124,12,31,0.16);",
    "  border:1px solid rgba(255,246,229,0.22);",
    "  opacity:0;pointer-events:none;text-decoration:none;",
    "  transition:opacity .25s ease,padding-right .25s ease;",
    "  user-select:none;-webkit-user-select:none;cursor:pointer;",
    "}",
    ".agd-projector-fab.is-on{opacity:.55;pointer-events:auto;}",
    ".agd-projector-fab.is-on:hover,.agd-projector-fab.is-on.is-open{",
    "  opacity:1;padding-right:18px;width:248px;",
    "}",
    ".agd-projector-fab{transition:opacity .25s ease,padding-right .25s ease,width .25s ease;}",
    ".agd-projector-fab .agd-fab-icon{",
    "  width:20px;height:20px;display:flex;align-items:center;",
    "  justify-content:center;flex-shrink:0;",
    "}",
    ".agd-projector-fab .agd-fab-icon svg{display:block;}",
    ".agd-projector-fab .agd-fab-label{",
    "  font-size:10px;letter-spacing:.12em;text-transform:uppercase;",
    "  font-weight:600;color:rgba(255,246,229,0.85);",
    "  width:0;opacity:0;overflow:hidden;white-space:nowrap;",
    "  transition:width .22s ease,opacity .22s ease;",
    "}",
    /* Label width matched to volume pill's expanded extras (slider 158
       + gap 10 + pct 26 = 194). Total expanded content = icon 20 + gap
       10 + label 194 = 224, identical to volume's expanded content. */
    ".agd-projector-fab:hover .agd-fab-label,",
    ".agd-projector-fab.is-open .agd-fab-label{width:194px;opacity:1;}",
  ].join("");

  function injectStyle() {
    if (document.getElementById("agd-flash-bridge-css")) return;
    var s = document.createElement("style");
    s.id = "agd-flash-bridge-css";
    s.textContent = STYLE;
    (document.head || document.documentElement).appendChild(s);
  }
  injectStyle();

  // ----------------------------------------------------------- helpers
  function toLaunchURL(swfUrl) {
    try {
      var u = new URL(swfUrl, document.baseURI);
      if (u.protocol === "agd:" || u.protocol === "http:" || u.protocol === "https:") {
        return "agd-launch://" + u.host + u.pathname + (u.search || "");
      }
      return "agd-launch://www.americangirl.com/" + String(swfUrl).replace(/^\/+/, "");
    } catch (e) {
      return "agd-launch://www.americangirl.com/" + String(swfUrl).replace(/^\/+/, "");
    }
  }

  function prettyName(swfUrl) {
    try {
      var u = new URL(swfUrl, document.baseURI);
      var leaf = u.pathname.split("/").filter(Boolean).pop() || "Flash content";
      leaf = leaf.replace(/\.(swf|spl)$/i, "");
      leaf = leaf.replace(/[_-]+/g, " ").replace(/([a-z])([A-Z])/g, "$1 $2");
      return leaf.replace(/\b\w/g, function (c) { return c.toUpperCase(); });
    } catch (e) { return "Flash content"; }
  }

  // Exposed below as window.__AGD_BUILD_STUB__ so the inline player page
  // (runtime/player.html) can render the same fallback when Ruffle fails.
  function buildStub(swfUrl, width, height) {
    var w = parseInt(width, 10) || 0;
    var h = parseInt(height, 10) || 0;
    var stub = document.createElement("a");
    stub.className = "agd-flash-stub";
    stub.href = toLaunchURL(swfUrl);
    stub.setAttribute("data-agd-swf", swfUrl);
    if (w > 0) stub.style.width = w + "px";
    if (h > 0) stub.style.height = h + "px";
    var minDim = Math.min(w || 480, h || 320);
    if (minDim < 120) stub.classList.add("agd-tiny");
    else if (minDim < 260) stub.classList.add("agd-small");
    var inner = document.createElement("div");
    inner.className = "agd-inner";
    inner.innerHTML =
      '<div class="agd-title">' + prettyName(swfUrl) + "</div>" +
      '<div class="agd-pill">&#9654; Open in Flash Player</div>';
    stub.appendChild(inner);
    return stub;
  }
  window.__AGD_BUILD_STUB__ = buildStub;

  /* Sepia placeholder for SWFs in LOST_SWFS. Same sizing chassis as
     buildStub but plain <div> (not <a>) — not clickable, no Flash
     Player handoff. Reads as a preservation note. */
  function buildLostStub(swfUrl, width, height) {
    var w = parseInt(width, 10) || 0;
    var h = parseInt(height, 10) || 0;
    var stub = document.createElement("div");
    stub.className = "agd-flash-stub agd-lost";
    stub.setAttribute("data-agd-swf", swfUrl);
    if (w > 0) stub.style.width = w + "px";
    if (h > 0) stub.style.height = h + "px";
    var minDim = Math.min(w || 480, h || 320);
    if (minDim < 120) stub.classList.add("agd-tiny");
    else if (minDim < 260) stub.classList.add("agd-small");
    var inner = document.createElement("div");
    inner.className = "agd-inner";
    inner.innerHTML =
      '<div class="agd-title">Lost to time</div>' +
      '<div class="agd-sub">This ecard’s animation wasn’t preserved by any archive we could reach.</div>';
    stub.appendChild(inner);
    return stub;
  }

  // Resolve a possibly-relative SWF URL against the current page.
  function absSwfURL(swfUrl) {
    try {
      return new URL(swfUrl, document.baseURI).href;
    } catch (e) { return swfUrl; }
  }

  function isFlashType(t) {
    return typeof t === "string" && /shockwave-flash/i.test(t);
  }

  function isDirectorType(t) {
    // application/x-director and assorted historical MIME types AG pages used
    // before settling on it.
    return typeof t === "string" && /x-director|director|shockwave[^-]/i.test(t);
  }

  // ----------------------------------------------------------- DCR stub
  /* Ask the host shell to launch the bundled Director projector. Tries the
     Mac WKWebView bridge first, then the Windows WebView2 bridge. Returns
     true if either accepted the message. Used by both the click handler
     and the auto-launch path; only the click path falls back to nav
     because scripted navigation to agd-launch:// silently fails without
     user activation (which a setTimeout from page load doesn't have).

     On Windows the embed rect is bundled with the launch request so the
     host can position the projector over the embed area in one shot. Mac
     gets the rect separately via the dcrRect handler driven by
     reportRect()/observers — that path is used for continuous tracking
     of the overlaid window, which Windows doesn't need (the projector
     is a separate floating window, not an overlay). */
  function postLaunchDCR(dcrUrl, stub) {
    try {
      if (window.webkit && window.webkit.messageHandlers
          && window.webkit.messageHandlers.launchDCR) {
        window.webkit.messageHandlers.launchDCR.postMessage(dcrUrl);
        return true;
      }
    } catch (e) {}
    try {
      if (window.chrome && window.chrome.webview
          && window.chrome.webview.postMessage) {
        var r = stub ? stub.getBoundingClientRect() : null;
        var payload = JSON.stringify({
          url:    dcrUrl,
          x:      r ? r.left   : 0,
          y:      r ? r.top    : 0,
          width:  r ? r.width  : 0,
          height: r ? r.height : 0,
          dpr:    window.devicePixelRatio || 1
        });
        window.chrome.webview.postMessage("launchDCR:" + payload);
        return true;
      }
    } catch (e) {}
    return false;
  }

  /* Shockwave Director (.dcr) variant of the crimson Flash stub. AG used
     Director for its richer mini-games — Addy's Mancala, Kit's egg hunt,
     Kirsten's Raccoon Caper, the puzzle pages, etc. Ruffle is Flash-only,
     so DCR <embed>s would render blank without us. We swap them for an
     actionable stub that fires `agd-launch://<dcr-url>` — the Swift
     NavigationHandler routes that to GameLauncher.launchDCR, which spins
     up the bundled Wine + Director projector. */
  function buildShockwaveStub(dcrUrl, width, height) {
    var w = parseInt(width, 10) || 0;
    var h = parseInt(height, 10) || 0;
    // (Used to add 28pt for the Wine title bar, but with Decorated=N
    //  in the Mac driver registry the Wine window is borderless — no
    //  title bar, no padding needed.)
    // Container is a plain DIV — NOT an <a>. Only the pill inside is the
    // clickable surface, so users get the right hover feedback + pointer
    // cursor only on the action target.
    var stub = document.createElement("div");
    stub.className = "agd-flash-stub agd-dcr";
    stub.setAttribute("data-agd-dcr", dcrUrl);
    stub.setAttribute("data-agd-original-swf", dcrUrl);  // so the FAB picks it up too
    if (w > 0) stub.style.width = w + "px";
    if (h > 0) stub.style.height = h + "px";
    var minDim = Math.min(w || 480, h || 320);
    if (minDim < 120) stub.classList.add("agd-tiny");
    else if (minDim < 260) stub.classList.add("agd-small");
    var inner = document.createElement("div");
    inner.className = "agd-inner";
    inner.innerHTML =
      '<div class="agd-title">' + prettyName(dcrUrl) + "</div>" +
      '<a class="agd-pill" href="' + toLaunchURL(dcrUrl) +
      '">&#9654; Opens in Director Projector — click to relaunch</a>';
    stub.appendChild(inner);

    // Pixelated retro loading overlay — visible from click until the host
    // shell tells us the projector window appeared (via __AGD_DCR_READY__
    // global hook the Swift overlay sets when AX detects the window).
    var loading = document.createElement("div");
    loading.className = "agd-loading";
    loading.innerHTML =
      '<div class="agd-logo"></div>' +
      '<div class="agd-bar"></div>' +
      '<div>Loading Shockwave Content…</div>';
    stub.appendChild(loading);

    var pill = inner.querySelector(".agd-pill");
    pill.addEventListener("click", function (e) {
      // Don't let the <a href="agd-launch://..."> actually navigate —
      // that pollutes WKWebView's history with a cancelled entry,
      // costing the user an extra Back press to escape the page.
      // Instead fire a script-message handler that calls into Swift's
      // GameLauncher directly. No history mutation.
      e.preventDefault();
      stub.classList.add("is-loading");
      // Re-emit the embed's current viewport rect IMMEDIATELY before
      // we ask Swift to spawn — guarantees the freshest possible
      // measurement regardless of any window resize / scroll that
      // happened since the last debounced emit.
      reportRect(stub, dcrUrl);
      if (!postLaunchDCR(dcrUrl, stub)) {
        // Final fallback: legacy navigation path. User activation is
        // present here (we're in a click handler) so the agd-launch://
        // nav will actually fire and NavHandler will intercept it.
        try { window.location.href = pill.href; } catch (e2) {}
      }
      // Best-effort: hide loading state after 8s in case the host shell
      // never signals back (e.g., projector creation failed silently).
      setTimeout(function () { stub.classList.remove("is-loading"); }, 8000);
    });
    // Expose a hook so the Swift overlay can dismiss the loading state
    // as soon as the projector window is positioned over the embed.
    // Switch to "running" state — the stub becomes a transparent spacer
    // so Wine's window covers everything and gaps blend with page bg.
    stub.__agdDismissLoading = function () {
      stub.classList.remove("is-loading");
      stub.classList.add("is-projector-running");
    };
    // Reset the stub when the projector process exits (user closed the
    // window). Drop the loading state + bring the launch pill back to
    // its idle "click to play" appearance.
    stub.__agdProjectorClosed = function () {
      stub.classList.remove("is-loading");
      stub.classList.remove("is-projector-running");
      var p = stub.querySelector(".agd-pill");
      if (p) p.innerHTML = "&#9654; Click to play again";
    };
    if (!window.__AGD_DCR_STUBS__) window.__AGD_DCR_STUBS__ = [];
    window.__AGD_DCR_STUBS__.push(stub);

    // Auto-launch the projector immediately on page load — like a
    // native game site would auto-start a Director embed. The user
    // shouldn't have to click an extra "play" pill to get the game
    // running. 250ms delay lets the page paint + JS report the rect
    // before we ask Swift to spawn Wine.
    setTimeout(function () { reportRect(stub, dcrUrl); }, 60);
    if (!window.__AGD_DCR_AUTOLAUNCHED__) {
      window.__AGD_DCR_AUTOLAUNCHED__ = true;
      setTimeout(function () {
        reportRect(stub, dcrUrl);
        stub.classList.add("is-loading");
        // No nav fallback here — user activation is required for scripted
        // navigation to a custom scheme, and a setTimeout from page load
        // has none. postLaunchDCR uses postMessage on both Mac and Windows,
        // which is exempt from that restriction.
        postLaunchDCR(dcrUrl, stub);
        // Safety: dismiss loading in case the host never signals back. On
        // Mac the overlay signals dismissal in ~1s; on Windows the
        // projector is a separate window with no signal-back channel, so
        // this timeout is the dismissal path.
        setTimeout(function () { stub.classList.remove("is-loading"); }, 8000);
      }, 250);
    }

    // Re-emit the rect on layout changes so the projector follows when
    // the user scrolls / resizes the WebView. The host shell additionally
    // listens for window-frame moves at the AppKit layer and re-applies.
    var emitT = 0;
    function emitSoon() {
      clearTimeout(emitT);
      emitT = setTimeout(function () { reportRect(stub, dcrUrl); }, 80);
    }
    window.addEventListener("scroll", emitSoon, { passive: true });
    window.addEventListener("resize", emitSoon);
    var ro;
    if (typeof ResizeObserver !== "undefined") {
      try { ro = new ResizeObserver(emitSoon); ro.observe(stub); } catch (e) {}
    }

    return stub;
  }

  // Post the stub's viewport rect to the host shell so the bundled
  // projector window can be positioned exactly over it.
  function reportRect(stub, dcrUrl) {
    try {
      if (!window.webkit
          || !window.webkit.messageHandlers
          || !window.webkit.messageHandlers.dcrRect) return;
      var r = stub.getBoundingClientRect();
      window.webkit.messageHandlers.dcrRect.postMessage({
        url:    dcrUrl,
        x:      r.left,
        y:      r.top,
        width:  r.width,
        height: r.height,
        dpr:    window.devicePixelRatio || 1,
        vpW:    window.innerWidth  || 0,
        vpH:    window.innerHeight || 0,
      });
    } catch (e) {}
  }

  // ----------------------------------------------------------- Ruffle helpers
  /* Returns a Ruffle player element configured for `url`, or null if Ruffle
     isn't ready yet (which shouldn't happen because we load ruffle.js
     synchronously before this script's effects take hold). The returned
     element auto-loads + auto-plays as soon as it's connected to the DOM. */
  function makeRuffle(url, width, height, bgColor, flashvars) {
    var wantW = parseInt(width, 10) || 0;
    var wantH = parseInt(height, 10) || 0;

    // Known-lost SWFs short-circuit straight to the sepia "Lost to
    // time" stub. Without this, Ruffle would fetch, hit a 404, fire
    // loaderror, and fall through to buildStub's crimson "Open in
    // Flash Player" tile — which promises action that can't deliver.
    if (isLostSWF(url)) return buildLostStub(url, wantW, wantH);

    // Ruffle exposes a per-page registry of "newest" player versions on
    // window.RufflePlayer once ruffle.js has loaded.
    var R = window.RufflePlayer;
    if (!R || typeof R.newest !== "function") {
      // Ruffle not ready yet: create a placeholder we'll upgrade later.
      var placeholder = document.createElement("div");
      placeholder.className = "agd-ruffle-pending";
      placeholder.setAttribute("data-agd-swf", url);
      if (wantW > 0) placeholder.style.width  = wantW + "px";
      if (wantH > 0) placeholder.style.height = wantH + "px";
      placeholder.style.background = "#000";
      return placeholder;
    }

    var ruffle = R.newest();
    var player = ruffle.createPlayer();
    if (wantW > 0) player.style.width  = wantW + "px";
    if (wantH > 0) player.style.height = wantH + "px";

    /* Stash the config on the element. We call player.load() in
       loadPlayerWhenAttached() AFTER the element is inserted into the DOM,
       because Ruffle refuses to play disconnected elements. */
    var loadConfig = {
      url: url,
      autoplay: "on",
      unmuteOverlay: "hidden",
      allowScriptAccess: true,
    };
    if (bgColor) loadConfig.backgroundColor = bgColor;
    // Derive base from the EMBEDDING PAGE's directory, not the SWF's
    // directory. Two reasons:
    //   1. getURL("foo.htm") in the SWF should land in the page's
    //      directory (the way a browser would resolve an <a href="foo.htm">
    //      from the page). E.g. addy/freedom/menu.htm embeds sw/menu.swf
    //      whose buttons do getURL("addy3.htm"); the target lives in
    //      freedom/, not in sw/, so SWF-dir base would 404.
    //   2. Same-dir loadVars (e.g. coverpoll.swf's coverpoll_config.xml)
    //      still works in the common case where the SWF is embedded by
    //      its own dir's index.html — page-dir == SWF-dir in that case.
    try {
      var href = location.href;
      var hLastSlash = href.lastIndexOf("/");
      if (hLastSlash >= 0) loadConfig.base = href.substring(0, hLastSlash + 1);
    } catch (e) {}
    // Parse flashvars="key1=v1&key2=v2&..." into Ruffle's parameters
    // object. Without this, ja06/cover_poll and dakotamania SWFs never
    // get configUrl set, so they loop on a default config that doesn't
    // exist and stay stuck on the loading bar.
    if (flashvars && typeof flashvars === "string") {
      var params = {};
      flashvars.split("&").forEach(function (pair) {
        var eq = pair.indexOf("=");
        if (eq > 0) {
          try {
            params[decodeURIComponent(pair.slice(0, eq))] = decodeURIComponent(pair.slice(eq + 1));
          } catch (e) { /* skip malformed pair */ }
        }
      });
      if (Object.keys(params).length > 0) loadConfig.parameters = params;
    }
    player.__agdLoadConfig = loadConfig;
    player.setAttribute("data-agd-original-swf", url);

    function fallback(reason) {
      dbg("makeRuffle.fallback reason=", reason && (reason.message || reason.type || reason));
      try {
        var rect = player.getBoundingClientRect();
        var stub = buildStub(url, rect.width || wantW, rect.height || wantH);
        if (player.parentNode) player.parentNode.replaceChild(stub, player);
      } catch (e) { dbg("  fallback exception:", e.message); }
    }
    player.addEventListener("loaderror", fallback);
    player.addEventListener("error", fallback);
    player.addEventListener("loadedmetadata", function () { dbg("ruffle loadedmetadata for", url); });

    return player;
  }

  /* Call player.load() AFTER the element is connected to the document.
     If it isn't connected yet (e.g. parent hasn't been appended), retry on
     the next animation frame for up to ~1s. */
  function loadPlayerWhenAttached(player) {
    if (!player || !player.__agdLoadConfig) return;
    if (player.__agdLoadStarted) return;
    var cfg = player.__agdLoadConfig;
    var attempts = 0;
    function tryLoad() {
      if (player.__agdLoadStarted) return;
      if (!player.isConnected) {
        if (++attempts < 60) {
          requestAnimationFrame(tryLoad);
        }
        return;
      }
      player.__agdLoadStarted = true;
      try {
        dbg("loadPlayerWhenAttached.load()", cfg.url);
        var p = player.load(cfg);
        if (p && typeof p.then === "function") {
          p.then(function () { dbg("  -> resolved", cfg.url); })
           .catch(function (e) { dbg("  -> rejected", e && (e.message || e)); });
        }
      } catch (e) {
        dbg("  -> threw", e.message);
      }
    }
    tryLoad();
  }

  /* Upgrade any pending placeholders once Ruffle finishes loading. */
  function upgradePendingPlaceholders() {
    document.querySelectorAll(".agd-ruffle-pending").forEach(function (ph) {
      var url = ph.getAttribute("data-agd-swf");
      if (!url) return;
      var w = parseInt(ph.style.width, 10) || 0;
      var h = parseInt(ph.style.height, 10) || 0;
      var player = makeRuffle(url, w, h, null);
      if (ph.parentNode) ph.parentNode.replaceChild(player, ph);
      loadPlayerWhenAttached(player);
    });
  }

  // ----------------------------------------------------------- SWFObject 1.x shim
  /* The American Girl site uses SWFObject 1.5 throughout:
     ```
     var so = new SWFObject("video/hero.swf", "container", "750", "305", "7", "#FFF");
     so.addParam("wmode", "opaque");
     so.write("flashcontent");        // replaces #flashcontent with the SWF
     ```
     Our shim makes `so.write(id)` build a <ruffle-player> inside #id
     instead. */
  function SWFObjectShim(swfUrl, id, width, height, version, bgcolor) {
    this._swf = swfUrl;
    this._id = id;
    this._width = width;
    this._height = height;
    this._version = version;
    this._bgcolor = bgcolor;
    this._params = {};
    this._vars = {};
    this._attrs = {};
  }
  SWFObjectShim.prototype.addParam = function (n, v) { this._params[n] = v; };
  SWFObjectShim.prototype.addVariable = function (n, v) { this._vars[n] = v; };
  SWFObjectShim.prototype.addAttribute = function (n, v) { this._attrs[n] = v; };
  SWFObjectShim.prototype.useExpressInstall = function () { /* no-op */ };
  SWFObjectShim.prototype.setAttribute = SWFObjectShim.prototype.addAttribute;
  SWFObjectShim.prototype.getAttribute = function (n) { return this._attrs[n]; };
  SWFObjectShim.prototype.getVariable = function (n) { return this._vars[n]; };
  SWFObjectShim.prototype.getVariablePairs = function () {
    var out = [];
    for (var k in this._vars) out.push(k + "=" + this._vars[k]);
    return out;
  };
  SWFObjectShim.prototype.getSWFHTML = function () { return ""; };
  SWFObjectShim.prototype.write = function (targetId) {
    var resolved = absSwfURL(this._swf);
    if (this._vars && Object.keys(this._vars).length) {
      var pairs = this.getVariablePairs().join("&");
      resolved += (resolved.indexOf("?") < 0 ? "?" : "&") + pairs;
    }
    var bg = this._bgcolor || this._params.bgcolor || null;
    dbg("SWFObjectShim.write target=", targetId, "url=", resolved,
        "size=", this._width + "x" + this._height, "RufflePlayer?=", !!window.RufflePlayer);
    var player = makeRuffle(resolved, this._width, this._height, bg);
    dbg("  player tag=", player.tagName, "class=", player.className);
    var target = document.getElementById(targetId);
    if (target) {
      dbg("  target found:", target.tagName, "#" + target.id);
      target.innerHTML = "";
      target.appendChild(player);
    } else {
      dbg("  target #" + targetId + " not found, appending to body");
      // The original SWFObject 1.x writes into document by default. Append
      // to body so the user still sees the game even without a target.
      (document.body || document.documentElement).appendChild(player);
    }
    loadPlayerWhenAttached(player);
    return true;
  };

  // SWFObject 2.x (some pages used the rewritten API)
  function swfobjectEmbedSWF(swfUrl, id, width, height, version, expressInstallSwfUrl,
                              flashvars, params, attributes, callbackFn) {
    var resolved = absSwfURL(swfUrl);
    if (flashvars && typeof flashvars === "object") {
      var pairs = [];
      for (var k in flashvars) pairs.push(encodeURIComponent(k) + "=" + encodeURIComponent(flashvars[k]));
      if (pairs.length) resolved += (resolved.indexOf("?") < 0 ? "?" : "&") + pairs.join("&");
    }
    var bg = (params && params.bgcolor) || null;
    var player = makeRuffle(resolved, width, height, bg);
    var target = document.getElementById(id);
    if (target) {
      target.innerHTML = "";
      target.appendChild(player);
    }
    loadPlayerWhenAttached(player);
    if (typeof callbackFn === "function") {
      try { callbackFn({ success: true, id: id, ref: player }); } catch (e) {}
    }
  }

  var swfobjectFacade = {
    embedSWF: swfobjectEmbedSWF,
    switchOffAutoHideShow: function () {},
    ua: { w3: true, pv: [10, 0, 0], wk: false, ie: false, win: false, mac: true },
    getFlashPlayerVersion: function () { return { major: 32, minor: 0, release: 0 }; },
    hasFlashPlayerVersion: function () { return true; },
    createSWF: function (attrs, params, id) {
      var url = attrs && (attrs.data || attrs.movie);
      var w = attrs && attrs.width, h = attrs && attrs.height;
      var player = makeRuffle(absSwfURL(url), w, h, params && params.bgcolor);
      var target = document.getElementById(id);
      if (target && target.parentNode) target.parentNode.replaceChild(player, target);
      loadPlayerWhenAttached(player);
      return player;
    },
    removeSWF: function (id) {
      var el = document.getElementById(id);
      if (el && el.parentNode) el.parentNode.removeChild(el);
      return !!el;
    },
    createCSS: function () {},
    addDomLoadEvent: function (fn) { if (typeof fn === "function") setTimeout(fn, 0); },
    addLoadEvent: function (fn) { if (typeof fn === "function") setTimeout(fn, 0); },
    getQueryParamValue: function (param) {
      var q = location.search.substring(1).split("&");
      for (var i = 0; i < q.length; i++) {
        var p = q[i].split("=");
        if (decodeURIComponent(p[0]) === param) return decodeURIComponent(p[1] || "");
      }
      return "";
    },
    expressInstallCallback: function () {},
  };

  // Lock our shims against the mirrored swfobject.js overwriting them.
  function lockGlobal(name, value) {
    try {
      Object.defineProperty(window, name, {
        configurable: true,
        enumerable: true,
        get: function () { return value; },
        set: function () { /* swallow page assignments */ },
      });
    } catch (e) {
      window[name] = value;
    }
  }
  lockGlobal("SWFObject", SWFObjectShim);
  lockGlobal("FlashObject", SWFObjectShim);  // older name used by SWFObject <1.0
  lockGlobal("swfobject", swfobjectFacade);
  // The mirrored swfobject.js also stuffs things under window.deconcept.*
  // (the original author's namespace). Pre-create that so it lives and dies
  // with our shim.
  try {
    var dec = window.deconcept = window.deconcept || {};
    dec.SWFObject = SWFObjectShim;
    dec.FlashObject = SWFObjectShim;
    dec.SWFObjectUtil = {
      getPlayerVersion: function () { return { major: 32, minor: 0, rev: 0 }; },
      cleanupSWFs: function () {},
    };
  } catch (e) {}

  // ----------------------------------------------------------- Safety net
  /* For any leftover raw <object data="...swf"> or <embed src="...swf"> tags
     that bypassed both Ruffle's polyfill and our SWFObject shim, replace
     them with inline Ruffle players. */
  function safetyNetReplace(root) {
    root = root || document;
    root.querySelectorAll("object").forEach(function (obj) {
      var tag = obj.tagName.toLowerCase();
      if (tag === "ruffle-object" || tag === "ruffle-embed") return;
      var type = obj.getAttribute("type") || "";
      var data = obj.getAttribute("data") || "";
      // Director (.dcr) embeds go to the Shockwave stub, not Ruffle.
      var srcParam = obj.querySelector('param[name="src" i],param[name="movie" i]');
      var paramVal = srcParam ? (srcParam.getAttribute("value") || "") : "";
      var combined = data || paramVal;
      if (/\.dcr(\?|$)/i.test(combined) || isDirectorType(type)) {
        var dcrUrl = absSwfURL(combined);
        if (!dcrUrl) return;
        var dw = obj.getAttribute("width") || obj.style.width;
        var dh = obj.getAttribute("height") || obj.style.height;
        var stub = buildShockwaveStub(dcrUrl, dw, dh);
        obj.parentNode && obj.parentNode.replaceChild(stub, obj);
        return;
      }
      if (!isFlashType(type) && !/\.swf(\?|$)/i.test(data)) {
        if (paramVal) data = paramVal;
        if (!/\.swf(\?|$)/i.test(data)) return;
      }
      if (!data) return;
      var w = obj.getAttribute("width") || obj.style.width;
      var h = obj.getAttribute("height") || obj.style.height;
      var bgParam = obj.querySelector('param[name="bgcolor" i]');
      var bg = bgParam ? bgParam.getAttribute("value") : null;
      var fvParam = obj.querySelector('param[name="flashvars" i]');
      var fv = fvParam ? fvParam.getAttribute("value") : null;
      var player = makeRuffle(absSwfURL(data), w, h, bg, fv);
      obj.parentNode && obj.parentNode.replaceChild(player, obj);
      loadPlayerWhenAttached(player);
    });
    root.querySelectorAll("embed").forEach(function (em) {
      var tag = em.tagName.toLowerCase();
      if (tag === "ruffle-object" || tag === "ruffle-embed") return;
      var type = em.getAttribute("type") || "";
      var src  = em.getAttribute("src") || "";
      // Director (.dcr) embeds: actionable Shockwave stub.
      if (/\.dcr(\?|$)/i.test(src) || isDirectorType(type)) {
        var dcrUrl = absSwfURL(src);
        if (!dcrUrl) return;
        var dw = em.getAttribute("width") || em.style.width;
        var dh = em.getAttribute("height") || em.style.height;
        var stub = buildShockwaveStub(dcrUrl, dw, dh);
        em.parentNode && em.parentNode.replaceChild(stub, em);
        return;
      }
      if (!isFlashType(type) && !/\.swf(\?|$)/i.test(src)) return;
      var w = em.getAttribute("width") || em.style.width;
      var h = em.getAttribute("height") || em.style.height;
      var player = makeRuffle(absSwfURL(src), w, h, em.getAttribute("bgcolor"), em.getAttribute("flashvars"));
      em.parentNode && em.parentNode.replaceChild(player, em);
      loadPlayerWhenAttached(player);
    });
  }

  // ----------------------------------------------------------- projector FAB
  /* When at least one Ruffle player exists on the page, show a small
     floating "Open in Flash Projector" button so the user can escape to
     the real Adobe projector with one click when Ruffle stumbles on a
     particular game's ActionScript. Picks the most recently created
     player as the link target.
  */
  function ensureProjectorFab() {
    var fab = document.getElementById("agd-projector-fab");
    var players = document.querySelectorAll('[data-agd-original-swf],[data-agd-swf]');
    if (!players.length) {
      if (fab) fab.classList.remove("is-on");
      return;
    }
    if (!fab) {
      fab = document.createElement("a");
      fab.id = "agd-projector-fab";
      fab.className = "agd-projector-fab";
      // Flash logo: a stylized lightning bolt — the universal shorthand
      // for "Flash content". Same currentColor cream as the volume icon,
      // same 20×20 footprint, so the two pills line up pixel-for-pixel.
      fab.innerHTML =
        '<span class="agd-fab-icon">' +
        '<svg viewBox="0 0 20 20" width="20" height="20" aria-hidden="true">' +
        '<path d="M11 1 L4 11 H9 L8 19 L16 8 H11 Z" fill="currentColor"/>' +
        '</svg></span>' +
        '<span class="agd-fab-label">Open in Flash Projector</span>';
      (document.body || document.documentElement).appendChild(fab);
    }
    // Pick the LAST (most recently inserted) player whose URL we know.
    var target = players[players.length - 1];
    var swfUrl = target.getAttribute("data-agd-original-swf")
              || target.getAttribute("data-agd-swf") || "";
    if (!swfUrl) {
      fab.classList.remove("is-on");
      return;
    }
    fab.href = toLaunchURL(swfUrl);
    fab.classList.add("is-on");
  }

  // ----------------------------------------------------------- ecard personalize
  /* AG's 2008 ecard wrappers POST to /ecards/customize.php — which by the
     time Wayback crawled it was returning "E-Card Central is currently
     closed". We replace the dead "Customize Your E-Card" form with a
     real 3-step wizard (customize → preview → send) hosted in
     mirror-runtime/ecard-wizard.html, and ALSO keep a quick inline
     personalize bar for users who just want to tweak the message without
     going through the full send flow.

     Step 3 of the wizard hands off to macOS Mail.app via a mailto: URL so
     the e-card can actually leave the machine if the user wants. */
  function enhanceEcardWrapper() {
    // Detect ecard wrappers: URL contains /ecards/choose.php and there's a
    // Ruffle player whose source has a personalMsg query parameter.
    var path = location.pathname || "";
    if (!/\/ecards\/choose\.php/.test(path)) return;
    var players = document.querySelectorAll("ruffle-player,ruffle-object,ruffle-embed,[data-agd-original-swf]");
    if (!players.length) return;

    var player = players[0];
    var swfUrl = player.getAttribute("data-agd-original-swf")
              || player.getAttribute("data-agd-swf") || "";
    if (!swfUrl || !/[?&]personalMsg=/.test(swfUrl)) return;

    // Already enhanced? Bail.
    if (document.getElementById("agd-personalize")) return;

    // Rewrite the dead Customize form: send it to our wizard via GET,
    // passing the SWF URL, ecard_id, theme, and current page back-link.
    var ecardId = "", theme = "";
    var formNode = document.querySelector('form[action*="customize.php"]');
    if (formNode) {
      var idIn = formNode.querySelector('input[name="ecard_id"]');
      var thIn = formNode.querySelector('input[name="theme"]');
      ecardId = idIn ? idIn.value : "";
      theme   = thIn ? thIn.value : "";
    }
    // Also pull the ecard slug from the URL (?ecard=mollystar) since the
    // wrapper template doesn't carry the slug as a form input.
    var ecardKey = "";
    var slugMatch = location.search.match(/[?&]ecard=([^&]+)/);
    if (slugMatch) {
      try { ecardKey = decodeURIComponent(slugMatch[1]); }
      catch (e) { ecardKey = slugMatch[1]; }
    }
    var wizardURL = "agd://www.americangirl.com/__agd/ecard-wizard.html"
      + "?swf="   + encodeURIComponent(swfUrl)
      + "&id="    + encodeURIComponent(ecardId)
      + "&theme=" + encodeURIComponent(theme)
      + "&ecard=" + encodeURIComponent(ecardKey)
      + "&from="  + encodeURIComponent(location.href);

    document.querySelectorAll('form[action*="customize.php"]').forEach(function (f) {
      // Replace any submit button in the form with a real anchor to the wizard,
      // preserving the original button image so the UX looks identical.
      var submit = f.querySelector('input[type="image"], input[type="submit"], button[type="submit"]');
      var anchor = document.createElement("a");
      anchor.href = wizardURL;
      anchor.style.cssText = "display:inline-block;text-decoration:none;";
      if (submit && submit.tagName === "INPUT" && submit.type === "image" && submit.src) {
        var img = document.createElement("img");
        img.src = submit.src;
        img.alt = submit.alt || "Customize Your E-Card";
        img.border = 0;
        if (submit.width)  img.width  = submit.width;
        if (submit.height) img.height = submit.height;
        anchor.appendChild(img);
      } else {
        anchor.textContent = "Customize Your E-Card";
        anchor.style.cssText += "padding:8px 18px;background:#A6192E;color:#FBF6EB;border-radius:6px;font-family:-apple-system,sans-serif;font-size:12px;letter-spacing:.18em;text-transform:uppercase;font-weight:600;";
      }
      if (f.parentNode) f.parentNode.replaceChild(anchor, f);
    });

  }

  // ----------------------------------------------------------- run
  function run() {
    upgradePendingPlaceholders();
    safetyNetReplace(document);
    ensureProjectorFab();
    enhanceEcardWrapper();
  }

  function whenReady(cb) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", cb, { once: true });
    } else {
      cb();
    }
  }

  // Run when DOM is ready. Then re-run a couple of times in case page
  // scripts inject Flash content asynchronously.
  whenReady(function () {
    run();
    setTimeout(run, 300);
    setTimeout(run, 1500);

    var mo = new MutationObserver(function () { run(); });
    mo.observe(document.body, { childList: true, subtree: true });
  });

  // Some pages (like the homepage) inject SWFObjects via inline scripts that
  // run BEFORE DOMContentLoaded. The shim is already locked in place above,
  // so those calls land on our shim and become pending placeholders -- we
  // then upgrade them once Ruffle has finished loading.
  if (window.RufflePlayer) {
    upgradePendingPlaceholders();
  } else {
    var poll = setInterval(function () {
      if (window.RufflePlayer && typeof window.RufflePlayer.newest === "function") {
        clearInterval(poll);
        upgradePendingPlaceholders();
      }
    }, 80);
    setTimeout(function () { clearInterval(poll); }, 15000);
  }
})();
