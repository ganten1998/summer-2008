#!/usr/bin/env bash
# Tiny helper -- grab the few branding assets the dashboard needs from
# Wayback right now (logo, top-level CSS, hero shot) without waiting for
# the full mirror download.
set -uo pipefail
cd "$(dirname "$0")/.."

ASSETS=(
  "site/images/textMain.gif"
  "site/styles/styles.css"
  "site/images/imgMain.jpg"
  "site/images/7_2/main_nf.gif"
  "site/images/7_2/shopTop.gif"
  "site/images/7_2/playTop.gif"
  "site/images/7_2/visit_top.gif"
  "site/images/7_2/watch_top.gif"
  "site/images/7_2sitehome.swf"
)

for path in "${ASSETS[@]}"; do
  out="mirror/www.americangirl.com/$path"
  /bin/mkdir -p "$(/usr/bin/dirname "$out")"
  if [[ ! -s "$out" ]]; then
    code=$(/usr/bin/curl -sSL --max-time 30 -w "%{http_code}" -o "$out" \
      "https://web.archive.org/web/20080711092743id_/http://www.americangirl.com/$path")
    sz=$(/usr/bin/stat -f%z "$out" 2>/dev/null || echo 0)
    echo "  $code  $sz  $path"
    [[ "$code" != "200" ]] && /bin/rm -f "$out"
    /bin/sleep 0.6
  else
    echo "  ok-cached  $(/usr/bin/stat -f%z "$out")  $path"
  fi
done
echo
echo "Logo file type:"
/usr/bin/file mirror/www.americangirl.com/site/images/textMain.gif 2>&1
