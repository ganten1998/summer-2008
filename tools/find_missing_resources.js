// Walk every HTML + CSS file under mirror/ and report references to assets
// that aren't present on disk. The Mac DMG was built from a richer local
// mirror that has files which never made it into git, so this enumerates
// the gap.
//
// Run:
//   node tools/find_missing_resources.js [--out missing.txt]
//
// Output: a text report grouped by host + directory, with a count of how
// many HTML files reference each missing asset, sorted by reference count
// (worst offenders first). Includes a CSV-style block at the bottom for
// piping into a recovery script.

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const MIRROR = path.join(ROOT, 'mirror');
// agd://runtime/* and agd://*/__agd/* both resolve to app/Resources/mirror-runtime,
// not mirror/. We probe that dir before declaring a runtime ref missing.
const MIRROR_RUNTIME = path.join(ROOT, 'app', 'Resources', 'mirror-runtime');
const RUNTIME_MARKER = '__agd/';
const STORE_HOSTS = new Set([
  'store.americangirl.com',
  'stage.store.americangirl.com',
  'shop.americangirl.com',
  'club.americangirl.com',
  'aka.www.americangirl.com',
  'mollysblog.americangirl.com',
  'emailresp.americangirl.com',
  'mresponse.americangirl.com',
]);
const SKIP_SCHEMES = new Set([
  'http:', 'https:', 'mailto:', 'tel:', 'sms:', 'facetime:',
  'javascript:', 'data:', 'about:', 'blob:', 'ftp:', 'file:',
]);
const ASSET_EXT_RE = /\.(html|htm|php|asp|aspx|cgi|jsp|js|mjs|css|jpg|jpeg|png|gif|svg|ico|webp|woff|woff2|ttf|otf|swf|dcr|dir|dxr|flv|mp3|mp4|mov|wav|ogg|wasm|json|xml|pdf)$/i;

// Mirror MirrorHandler.cs's ResolveMirrorPath query-suffix sanitization
// so we look up files exactly the way the shell does at runtime.
function sanitizeQuery(q) {
  let safe = q.replace(/[^A-Za-z0-9._-]+/g, '_');
  safe = safe.replace(/[. ]+$/g, '');
  if (safe.length > 128) {
    safe = safe.slice(0, 128).replace(/[. ]+$/g, '');
  }
  return safe;
}

function resolveToAgdUrl(baseHost, baseDir, ref) {
  // baseHost: 'www.americangirl.com' etc.
  // baseDir: '/agcn/kit/' (relative to host root, ALWAYS ends with /)
  // ref: the raw href/src text
  ref = ref.trim();
  if (!ref) return null;
  // Drop fragment
  const hashIdx = ref.indexOf('#');
  if (hashIdx >= 0) ref = ref.slice(0, hashIdx);
  if (!ref) return null;

  // Filter out non-asset schemes
  const schemeMatch = /^([a-z][a-z0-9+.-]*):/i.exec(ref);
  if (schemeMatch) {
    const scheme = (schemeMatch[1] + ':').toLowerCase();
    if (scheme === 'agd:') {
      // agd://host/path[?query]
      try {
        const u = new URL(ref);
        return { host: u.hostname, pathname: u.pathname, search: u.search };
      } catch { return null; }
    }
    if (SKIP_SCHEMES.has(scheme)) return null;
    return null;
  }
  // Protocol-relative: //host/path
  if (ref.startsWith('//')) {
    try {
      const u = new URL('agd:' + ref);
      return { host: u.hostname, pathname: u.pathname, search: u.search };
    } catch { return null; }
  }
  // Absolute path: /foo/bar.gif → resolve against current host root
  let pathname, search = '';
  if (ref.startsWith('/')) {
    const qIdx = ref.indexOf('?');
    pathname = qIdx < 0 ? ref : ref.slice(0, qIdx);
    search = qIdx < 0 ? '' : ref.slice(qIdx);
  } else {
    // Relative: resolve against baseDir
    const qIdx = ref.indexOf('?');
    const refPath = qIdx < 0 ? ref : ref.slice(0, qIdx);
    search = qIdx < 0 ? '' : ref.slice(qIdx);
    // Join baseDir + refPath then normalize
    const joined = baseDir + refPath;
    const parts = joined.split('/');
    const stack = [];
    for (const p of parts) {
      if (p === '' || p === '.') continue;
      if (p === '..') { stack.pop(); continue; }
      stack.push(p);
    }
    pathname = '/' + stack.join('/');
  }
  return { host: baseHost, pathname, search };
}

function expectedOnDiskPath(parsed) {
  // parsed: { host, pathname, search }
  let p = parsed.pathname;
  if (p.endsWith('/')) p += 'index.html';
  let full = path.join(MIRROR, parsed.host, p.replace(/^\//, '').split('/').join(path.sep));
  if (parsed.search) {
    const q = parsed.search.replace(/^\?/, '');
    full += '__' + sanitizeQuery(q);
  }
  return full;
}

function shouldIgnore(parsed, ref) {
  if (!parsed) return true;
  // Synthetic runtime paths — agd://<any-host>/__agd/* maps to mirror-runtime/
  if (parsed.pathname.includes(RUNTIME_MARKER)) {
    const sub = parsed.pathname.slice(parsed.pathname.indexOf(RUNTIME_MARKER) + RUNTIME_MARKER.length);
    return fs.existsSync(path.join(MIRROR_RUNTIME, sub.split('/').join(path.sep)));
  }
  // agd://runtime/* — also mirror-runtime/
  if (parsed.host === 'runtime') {
    const sub = parsed.pathname.replace(/^\//, '');
    return fs.existsSync(path.join(MIRROR_RUNTIME, sub.split('/').join(path.sep)));
  }
  // Tracking pixels rewritten by patcher to agd://disabled
  if (parsed.host === 'disabled') return true;
  // Store hosts — handled by stub
  if (STORE_HOSTS.has(parsed.host.toLowerCase())) return true;
  // The "1x1 transparent" tracking pixel
  if (/\/agp\.gif$/i.test(parsed.pathname) && parsed.host === 'www.americangirl.com') {
    // Actually agp.gif IS on disk for most cases; the misses are intra-store. Leave it.
  }
  // Skip anchor-only / empty / pure query-string-only refs that don't carry a path
  if (!parsed.pathname || parsed.pathname === '/' || parsed.pathname === '') return true;
  return false;
}

function* walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else yield full;
  }
}

// Extraction regexes — tolerant of single + double quotes + no quotes.
const SRC_RE  = /\b(?:src|href|data|action|poster|background|formaction)\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>'"]+))/gi;
const URL_RE  = /\burl\(\s*(?:"([^"]+)"|'([^']+)'|([^\s)]+))\s*\)/g;

function extractRefs(text) {
  const refs = new Set();
  let m;
  while ((m = SRC_RE.exec(text)) !== null) {
    const v = m[1] || m[2] || m[3];
    if (v) refs.add(v);
  }
  while ((m = URL_RE.exec(text)) !== null) {
    const v = m[1] || m[2] || m[3];
    if (v) refs.add(v);
  }
  return refs;
}

function main() {
  const argv = process.argv.slice(2);
  const outArg = argv.find((a, i) => argv[i - 1] === '--out');
  const outFile = outArg || path.join(ROOT, 'missing_resources.txt');

  const missing = new Map(); // expectedOnDiskPath -> { url, refs: Set<sourceFile> }
  let scannedHtml = 0, scannedCss = 0, scannedRefs = 0;

  for (const file of walk(MIRROR)) {
    const lower = file.toLowerCase();
    const isHtml = /\.(html?|php|asp|aspx|jsp|cgi)$/i.test(lower);
    const isCss  = /\.css$/i.test(lower);
    if (!isHtml && !isCss) continue;
    if (isHtml) scannedHtml++; else scannedCss++;

    let text;
    try { text = fs.readFileSync(file, 'utf8'); }
    catch { continue; }
    const refs = extractRefs(text);

    // Source file's location → host + dir within mirror
    const rel = path.relative(MIRROR, file).split(path.sep);
    const host = rel[0];
    const dirParts = rel.slice(1, -1);
    const baseDir = '/' + dirParts.join('/') + (dirParts.length ? '/' : '');

    for (const ref of refs) {
      scannedRefs++;
      const parsed = resolveToAgdUrl(host, baseDir, ref);
      if (shouldIgnore(parsed, ref)) continue;
      // Only consider asset-like extensions; skip nav links to .html pages we don't have
      // (those are expected — the mirror is partial by design). We DO include .html
      // refs from <img>/<script>/<link>/<embed>/<object>/etc., which the SRC_RE catches.
      // But we want to skip <a href="some.html"> dead-links. Heuristic: an extension-less
      // path or .html path being missing is not interesting; an image/css/js/swf missing IS.
      const ext = path.extname(parsed.pathname).toLowerCase();
      if (ext === '.html' || ext === '.htm' || ext === '.php' || ext === '.asp' ||
          ext === '.aspx' || ext === '.jsp' || ext === '.cgi' || ext === '') continue;
      if (!ASSET_EXT_RE.test(parsed.pathname)) continue;

      const onDisk = expectedOnDiskPath(parsed);
      if (fs.existsSync(onDisk)) continue;

      const url = 'agd://' + parsed.host + parsed.pathname + parsed.search;
      let bucket = missing.get(onDisk);
      if (!bucket) {
        bucket = { url, refs: new Set(), host: parsed.host, pathname: parsed.pathname, search: parsed.search };
        missing.set(onDisk, bucket);
      }
      bucket.refs.add(path.relative(ROOT, file).split(path.sep).join('/'));
    }
  }

  // Group by host then directory for readability.
  const byHost = new Map();
  for (const [onDisk, info] of missing) {
    const dirKey = info.host + ':' + path.posix.dirname(info.pathname);
    let arr = byHost.get(info.host);
    if (!arr) { arr = []; byHost.set(info.host, arr); }
    arr.push({ onDisk, ...info });
  }
  for (const arr of byHost.values()) {
    arr.sort((a, b) => {
      const ad = path.posix.dirname(a.pathname);
      const bd = path.posix.dirname(b.pathname);
      if (ad !== bd) return ad.localeCompare(bd);
      return a.pathname.localeCompare(b.pathname);
    });
  }

  const out = [];
  out.push('Summer 2008 — missing mirror resources');
  out.push('=======================================');
  out.push('');
  out.push('Generated: ' + new Date().toISOString());
  out.push('Scanned:   ' + scannedHtml + ' HTML/PHP files + ' + scannedCss + ' CSS files');
  out.push('           ' + scannedRefs + ' total refs extracted');
  out.push('Missing:   ' + missing.size + ' unique asset paths');
  out.push('');
  out.push('Each missing asset shows:');
  out.push('  • agd:// URL the runtime expects');
  out.push('  • the on-disk path it would resolve to under mirror/');
  out.push('  • [count] referring HTML/CSS file(s) — first few shown');
  out.push('');
  out.push('Filters applied:');
  out.push('  • skipped agd://disabled/* (patcher-neutralized trackers)');
  out.push('  • skipped store/shop subdomains (handled by stub)');
  out.push('  • skipped __agd/ and agd://runtime/* paths verified against mirror-runtime/');
  out.push('  • skipped nav links to .html/.php (mirror is intentionally partial)');
  out.push('  • only assets (images, css, js, swf, dcr, audio, video, fonts, pdf)');
  out.push('');

  // Top offenders — most-referenced missing assets first. Knock these out
  // and most of the visual gaps disappear.
  out.push('================================================================');
  out.push('TOP 30 MOST-REFERENCED MISSING ASSETS');
  out.push('================================================================');
  const topAll = [...missing.values()]
    .map((m) => ({ url: m.url, count: m.refs.size }))
    .sort((a, b) => b.count - a.count);
  for (const t of topAll.slice(0, 30)) {
    out.push('  [' + String(t.count).padStart(4, ' ') + ']  ' + t.url);
  }
  out.push('');

  // Group by file-extension for quick "what kind of stuff is missing" feel
  out.push('================================================================');
  out.push('BREAKDOWN BY EXTENSION');
  out.push('================================================================');
  const byExt = new Map();
  for (const m of missing.values()) {
    const ext = path.extname(m.pathname).toLowerCase() || '(none)';
    byExt.set(ext, (byExt.get(ext) || 0) + 1);
  }
  const extEntries = [...byExt.entries()].sort((a, b) => b[1] - a[1]);
  for (const [ext, n] of extEntries) {
    out.push('  ' + ext.padEnd(8, ' ') + ' ' + String(n).padStart(5, ' '));
  }
  out.push('');

  const sortedHosts = [...byHost.keys()].sort();
  for (const host of sortedHosts) {
    out.push('================================================================');
    out.push('HOST: ' + host + '   (' + byHost.get(host).length + ' missing)');
    out.push('================================================================');
    let lastDir = null;
    for (const m of byHost.get(host)) {
      const dir = path.posix.dirname(m.pathname);
      if (dir !== lastDir) {
        out.push('');
        out.push('  ' + dir + '/');
        lastDir = dir;
      }
      out.push('    - ' + path.posix.basename(m.pathname) + (m.search || '')
               + '    [' + m.refs.size + ' ref' + (m.refs.size === 1 ? '' : 's') + ']');
      const refList = [...m.refs].slice(0, 3);
      for (const r of refList) out.push('        ← ' + r);
      if (m.refs.size > 3) out.push('        ← (... +' + (m.refs.size - 3) + ' more)');
    }
    out.push('');
  }

  // Final flat list, one URL per line, sorted, for easy piping
  out.push('================================================================');
  out.push('FLAT LIST (one URL per line — pipe-friendly):');
  out.push('================================================================');
  const flat = [...missing.values()].map((m) => m.url).sort();
  for (const u of flat) out.push(u);

  fs.writeFileSync(outFile, out.join('\n'), 'utf8');
  console.log('Wrote ' + outFile);
  console.log('Scanned: ' + scannedHtml + ' HTML/PHP + ' + scannedCss + ' CSS, ' + scannedRefs + ' refs');
  console.log('Missing: ' + missing.size + ' unique assets across ' + byHost.size + ' hosts');
}

main();
