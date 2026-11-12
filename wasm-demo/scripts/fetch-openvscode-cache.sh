#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fetch-openvscode-cache.sh — download the OpenVSCode Server release tarball
# and extract it as a host-side static-asset cache for the wasm demo.
#
# Why: the wasm guest runs OpenVSCode Server from an emulated x86_64 CPU; every
# static client asset served by the guest costs (slow) emulated CPU + network
# round-trips. If the same files are available on the host, the demo server
# serves `/stable-<commit>/static/...` directly from this cache, and only
# dynamic requests go through the emulated guest.
#
# Usage:
#   ./scripts/fetch-openvscode-cache.sh
#   ./scripts/serve-openvscode.sh     # picks up .cache/openvscode-<version>
#
# Download size: ~74 MB (extracted ~244 MB), cached; delete .cache/ to reclaim.
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OVS_VERSION=${OVS_VERSION:-1.109.5}
DEST=${STATIC_CACHE:-$ROOT/.cache/openvscode-$OVS_VERSION}

log() { printf '[fetch-openvscode-cache] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

if [ -x "$DEST/bin/openvscode-server" ]; then
  log "static cache already present: $DEST"
  exit 0
fi

URL="https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v${OVS_VERSION}/openvscode-server-v${OVS_VERSION}-linux-x64.tar.gz"
log "downloading OpenVSCode Server v${OVS_VERSION} (~74 MB)..."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ovs-cache.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
curl -fL --retry 3 --retry-delay 2 -o "$tmp/ovs.tar.gz" "$URL"

mkdir -p "$DEST"
log "extracting to $DEST ..."
tar -xzf "$tmp/ovs.tar.gz" --strip-components=1 -C "$DEST"
find "$DEST" -name '*.map' -delete 2>/dev/null || true
[ -x "$DEST/bin/openvscode-server" ] || die "extraction failed: $DEST/bin/openvscode-server not found"
log "done: $DEST ($(du -sh "$DEST" | cut -f1))"
log "run ./scripts/serve-openvscode.sh to use it"
