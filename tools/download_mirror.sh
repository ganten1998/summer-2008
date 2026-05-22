#!/usr/bin/env bash
# Download the americangirl.com Wayback snapshot anchored at 2008-07-11.
# Uses a generous "to" date so we capture every URL whose latest archive
# version is at-or-before our target snapshot.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export GEM_HOME="$ROOT/tools/gems"
export PATH="$ROOT/tools/gems/bin:$PATH"

# Anchor: 20080711092743 (the exact snapshot the user requested).
# We use -t 20080712000000 to include the full target day; the gem will keep
# only the most-recent archive copy of each URL on/before that timestamp,
# which mirrors how Wayback's "view this snapshot" actually resolves files.
exec wayback_machine_downloader \
  "http://www.americangirl.com/" \
  -d "$ROOT/mirror" \
  -t 20080712000000 \
  -c 10 \
  -a \
  -p 200
