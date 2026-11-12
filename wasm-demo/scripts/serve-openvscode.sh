#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# serve-openvscode.sh — serve the minimal OpenVSCode Server wasm image.
#
# This is a thin wrapper around ../scripts/serve.sh that changes the defaults
# to the small OpenVSCode Server artifact and a different set of local ports,
# so it can coexist with the bigger serve-web demo.
#
#   ./scripts/serve-openvscode.sh
#   # -> open http://localhost:8092/?net=delegate=ws://127.0.0.1:8889&port=18081
#
# Prerequisites (both optional but recommended):
#   ./scripts/fetch-openvscode-cache.sh   # host-side VS Code client assets (~74 MB)
#   # the wasm artifact is auto-downloaded from FRTI64/frti64_c2w (c2w-web-vscode-ovs-wasm)
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

export ARTIFACT_NAME=${ARTIFACT_NAME:-c2w-web-vscode-ovs-wasm}
export STATIC_CACHE=${STATIC_CACHE:-$ROOT/.cache/openvscode-1.109.5}
export PAGE_PORT=${PAGE_PORT:-8092}
export GUEST_PORT=${GUEST_PORT:-18081}
export WS_PORT=${WS_PORT:-8889}
# Default of serve.sh downloads into $ROOT/htdocs; keep a separate dir so both
# demos can be kept on disk side by side.
export IMAGE_DIR=${IMAGE_DIR:-$ROOT/htdocs-openvscode}

exec "$ROOT/scripts/serve.sh" "$@"
