#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# entrypoint.sh — minimal OpenVSCode Server launcher.
#
# All writable state lives under /tmp so the container never needs a writable
# root filesystem: this matters when the image is converted to WebAssembly by
# container2wasm (the guest rootfs is read-only and /tmp is RAM/tmpfs), and it
# also means the native container is ephemeral by design.
#
# Environment:
#   HOST              bind address                (default: 0.0.0.0)
#   PORT              HTTP port                   (default: 8000)
#   SERVER_DATA_DIR   user data / extensions dir  (default: /tmp/openvscode-data)
#   DEFAULT_FOLDER    folder opened on connect    (default: /tmp/workspace)
#   CONNECTION_TOKEN  if set, require ?tkn=/cookie auth (default: open access)
#
# Usage:
#   docker run IMAGE                          # start the server
#   docker run IMAGE bash                     # debug shell
#   docker run IMAGE --server-base-path /code # extra server args
# ---------------------------------------------------------------------------
set -euo pipefail

readonly HOST="${HOST:-0.0.0.0}"
readonly PORT="${PORT:-8000}"
readonly SERVER_DATA_DIR="${SERVER_DATA_DIR:-/tmp/openvscode-data}"
readonly DEFAULT_FOLDER="${DEFAULT_FOLDER:-/tmp/workspace}"
readonly SERVER_BIN="/opt/openvscode/bin/openvscode-server"

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# All of these must be writable. In the wasm guest the rootfs is read-only, so
# use /tmp (RAM) for HOME, XDG dirs and the workspace.
export HOME="${HOME:-/tmp/home}"
export TMPDIR="${TMPDIR:-/tmp/coder-tmp}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/coder-config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/coder-data}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/coder-cache}"
mkdir -p "$HOME" "$TMPDIR" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" \
  "$SERVER_DATA_DIR" "$DEFAULT_FOLDER"

# Pass-through: `docker run IMAGE bash` / `docker run IMAGE node --version`.
extra_args=()
if [ "$#" -gt 0 ]; then
  case "$1" in
    -*) extra_args=("$@") ;;
    *) log "executing: $*"; exec "$@" ;;
  esac
fi

[ -x "$SERVER_BIN" ] || { log "ERROR: $SERVER_BIN not found"; exit 1; }

args=(
  --host "$HOST"
  --port "$PORT"
  --accept-server-license-terms
  --telemetry-level off
  --server-data-dir "$SERVER_DATA_DIR"
  --default-folder "$DEFAULT_FOLDER"
)
if [ -n "${CONNECTION_TOKEN:-}" ]; then
  args+=(--connection-token "$CONNECTION_TOKEN")
else
  args+=(--without-connection-token)
fi
args+=("${extra_args[@]}")

if [ -n "${CONNECTION_TOKEN:-}" ]; then
  log "OpenVSCode Server: http://${HOST}:${PORT} (connection token enabled)"
else
  log "OpenVSCode Server: http://${HOST}:${PORT} (open access, no token)"
fi
log "workspace: ${DEFAULT_FOLDER}, data: ${SERVER_DATA_DIR} (all under /tmp = RAM in wasm guest)"

exec "$SERVER_BIN" "${args[@]}"
