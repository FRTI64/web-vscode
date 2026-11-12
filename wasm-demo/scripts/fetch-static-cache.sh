#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fetch-static-cache.sh — download the VS Code web-server files for the pinned
# commit and extract them into .cache/serve-web/<commit>.
#
# Why: the wasm container serves the whole VS Code client from an emulated
# x86_64 node process, which is slow (tens of seconds per asset). If the same
# files are available on the host, the demo server serves the static client
# assets directly (checked out of this cache) and only dynamic requests go
# through the emulated guest. This makes the workbench load in seconds.
#
# Usage:
#   ./scripts/fetch-static-cache.sh
#   ./scripts/serve.sh          # picks up .cache/serve-web/<commit> automatically
#
# The download is ~270 MB and is cached; delete .cache/ to reclaim the space.
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMIT=${VSCODE_COMMIT:-69047191fc427f2f92828279aae1d90d8eeda7ab}
DEST=${STATIC_CACHE:-$ROOT/.cache/serve-web/$COMMIT}

log() { printf '[fetch-static-cache] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

if [ -x "$DEST/bin/code-server" ]; then
  log "static cache already present: $DEST"
  exit 0
fi

URL="https://update.code.visualstudio.com/commit:${COMMIT}/server-linux-x64-web/stable"
log "downloading VS Code web server ($COMMIT, ~270 MB)..."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/vscode-web.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
curl -fL --retry 3 --retry-delay 2 -o "$tmp/server.tar.gz" "$URL"

mkdir -p "$DEST"
log "extracting to $DEST ..."
tar -xzf "$tmp/server.tar.gz" --strip-components=1 -C "$DEST"
[ -x "$DEST/bin/code-server" ] || die "extraction failed: $DEST/bin/code-server not found"
log "done: $DEST ($(du -sh "$DEST" | cut -f1))"
log "run ./scripts/serve.sh to use it"
