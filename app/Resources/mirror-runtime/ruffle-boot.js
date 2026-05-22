/* ruffle-boot.js
 *
 * Loaded BEFORE ruffle.js so that Ruffle picks up our configuration the
 * first time it initializes. See:
 *   https://github.com/ruffle-rs/ruffle/wiki/Using-Ruffle
 *
 * IMPORTANT: keep this small and synchronous -- ruffle.js reads
 * window.RufflePlayer.config at load time. We also set publicPath so the
 * WASM binaries (38798f07c2c84a0fc083.wasm, etc.) resolve correctly under
 * our custom agd:// URL scheme.
 */
(function () {
  "use strict";

  // Cached-volume bootstrap. Read the persisted slider value out of
  // localStorage BEFORE anything else so the AudioContext capture +
  // the RufflePlayer.config below both start in the right state. Default
  // is muted; users who'd set a volume previously get their value back.
  var bootVol = 0;
  var bootMuted = true;
  try {
    var __cached = localStorage.getItem("agd:volume:cache");
    if (__cached != null) {
      var __n = parseFloat(__cached);
      if (isFinite(__n) && __n >= 0 && __n <= 1) {
        bootVol = __n;
        bootMuted = __n <= 0.005;
      }
    }
  } catch (e) {}

  /* ──── Master gain injection + hard-mute ──────────────────────────
     We need TWO things to make a global volume slider work:

       1. Mid-range scaling (slider at 50% = half volume). Done by
          hijacking AudioNode.prototype.connect so any node that
          connects to ctx.destination gets routed through a per-context
          master GainNode first. Setting that gain to 0.5 actually
          halves output. Without this hijack, Ruffle connects its mix
          straight to ctx.destination and our standalone gain dangles
          in the graph with no effect.

       2. Hard mute (slider at 0). Done by suspending the AudioContext
          itself — kills audio at the WebAudio engine, no half-measures.

     Both rely on catching every AudioContext the page constructs, so we
     wrap the constructor here and run BEFORE ruffle.js loads. */
  (function setupAudio() {
    var contexts = new Set();
    var muted = bootMuted;     // boot in cached / default-muted state
    var currentGain = bootVol; // 0 by default → silent until slider

    function ensureMasterGain(ctx) {
      if (ctx.__agd_master_gain__) return ctx.__agd_master_gain__;
      var g = ctx.createGain();
      g.gain.value = currentGain;
      g.__agd_is_master__ = true;
      // Connect our master to the REAL destination via the original
      // (un-hijacked) connect — we stash a reference below.
      origConnect.call(g, ctx.destination);
      ctx.__agd_master_gain__ = g;
      return g;
    }

    // Stash the original connect BEFORE we patch it, so the master gain
    // itself can still reach ctx.destination without recursing.
    var origConnect = (window.AudioNode && window.AudioNode.prototype.connect);
    if (origConnect) {
      window.AudioNode.prototype.connect = function (target) {
        // If this is OUR master gain connecting to destination, let it through.
        if (this.__agd_is_master__) return origConnect.apply(this, arguments);
        // Otherwise, if anything connects to ctx.destination, redirect through
        // our master gain (which itself connects to the real destination).
        if (target && target.context && target === target.context.destination) {
          var g = ensureMasterGain(target.context);
          var args = [g].concat([].slice.call(arguments, 1));
          return origConnect.apply(this, args);
        }
        return origConnect.apply(this, arguments);
      };
    }

    function wrap(Orig) {
      if (!Orig || Orig.__agd_wrapped__) return Orig;
      function Wrapped() {
        var ctx = arguments.length
          ? new (Function.prototype.bind.apply(Orig, [null].concat([].slice.call(arguments))))()
          : new Orig();
        contexts.add(ctx);
        // Pre-create the master gain immediately so it's ready before
        // any audio nodes connect.
        try { ensureMasterGain(ctx); } catch (e) {}
        if (muted) { try { ctx.suspend(); } catch (e) {} }
        return ctx;
      }
      Wrapped.prototype = Orig.prototype;
      Wrapped.__agd_wrapped__ = true;
      try { Object.setPrototypeOf(Wrapped, Orig); } catch (e) {}
      return Wrapped;
    }
    try { window.AudioContext = wrap(window.AudioContext); } catch (e) {}
    try { window.webkitAudioContext = wrap(window.webkitAudioContext); } catch (e) {}

    // Hard mute via AudioContext.suspend — kills all audio on the
    // context regardless of gain settings.
    window.__AGD_AUDIO_MUTE__ = function (mute) {
      muted = !!mute;
      contexts.forEach(function (ctx) {
        try { mute ? ctx.suspend() : ctx.resume(); } catch (e) {}
      });
    };

    // Proportional volume via the per-context master gain. Linear
    // 0..1; the slider passes through as-is.
    window.__AGD_AUDIO_GAIN__ = function (v) {
      currentGain = Math.max(0, Math.min(1, +v));
      contexts.forEach(function (ctx) {
        try { ensureMasterGain(ctx).gain.value = currentGain; } catch (e) {}
      });
    };

    window.__AGD_AUDIO_CONTEXTS__ = contexts;
  })();

  window.RufflePlayer = window.RufflePlayer || {};
  window.RufflePlayer.config = Object.assign({
    /* Where the wasm + chunk files live (relative to runtime root) */
    publicPath: "agd://runtime/ruffle/",

    /* Play immediately, matching the 2008-era browser experience */
    autoplay: "on",
    unmuteOverlay: "hidden",
    splashScreen: false,

    /* Default volume / mute state — see volume-control.js. Defaults to
       muted; persisted via localStorage cache (read just above) so
       returning users keep whatever they'd set. */
    volume: bootVol,
    muted:  bootMuted,

    /* Replace <object>, <embed>, and SWFObject calls site-wide */
    polyfills: true,

    /* Less chatty UI */
    warnOnUnsupportedContent: false,
    showSwfDownload: false,
    contextMenu: "rightClickOnly",
    letterbox: "on",
    quality: "high",
    scale: "showAll",

    /* Be permissive about cross-asset references -- mirrored SWFs commonly
       load XML/JPG siblings that Ruffle would otherwise refuse. */
    allowScriptAccess: true,
    upgradeToHttps: false,
    backgroundColor: null,

    /* Don't suppress any default keys */
    preferredRenderer: "webgl",

    /* Pipe Flash's trace() output to console.log so the player page's
       diagnostics panel (and the dev console) capture it. Useful when a
       game emits "ERROR: …" via trace before failing visibly. */
    logLevel: "warn",
  }, window.RufflePlayer.config || {});

  /* Custom trace observer — Ruffle fires "loadedmetadata" but not a
     dedicated trace event; instead it writes via console.log when
     logLevel allows. We just make sure console.log is patched downstream
     by flash-bridge.js / player.html, which both do.
  */
})();
