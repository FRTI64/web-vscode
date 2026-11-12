#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# serve-local.sh — run Visual Studio Code's `code serve-web` directly on a
# Linux host, without Docker.
#
# The script downloads the official VS Code CLI once (pinned commit below),
# then starts the web UI and prints its URL.  The web server itself is
# downloaded by the VS Code CLI on first start (~270 MB) and cached, so the
# first launch takes a few minutes; subsequent launches are fast.
#
# Usage:
#   ./scripts/serve-local.sh [extra serve-web args...]
#
# Environment overrides:
#   PORT              port to listen on                       (default: 8000)
#   HOST              address to bind                          (default: 0.0.0.0)
#   CONNECTION_TOKEN  require ?tkn=<token> / cookie auth       (default: unset)
#   DEFAULT_FOLDER    folder opened when the browser connects  (default: $PWD)
#   VSCODE_COMMIT     VS Code commit to run                   (default: pinned)
#   VSCODE_CLI_DIR    where the CLI is installed  (default: $XDG_DATA_HOME/web-vscode/cli)
#   VSCODE_CLI_DATA_DIR  CLI cache (serve-web cache)          (default: <CLI_DIR>/data)
#   VSCODE_DATA_DIR   server data dir      (default: $XDG_DATA_HOME/web-vscode/server-data)
#
# Notes:
#   * Accepting the VS Code Server License Terms is required; this script
#     passes --accept-server-license-terms on your behalf.  See
#     https://aka.ms/vscode-server-license
#   * Binding 0.0.0.0 without a CONNECTION_TOKEN gives anyone who can reach
#     the port full access to the opened folder.  Use a token or a firewall
#     outside a throwaway dev box.
# ---------------------------------------------------------------------------
set -euo pipefail

# VS Code stable at the time this project was created.  Keep in sync with the
# Dockerfile ARG VSCODE_COMMIT.
DEFAULT_COMMIT="69047191fc427f2f92828279aae1d90d8eeda7ab"
VSCODE_COMMIT="${VSCODE_COMMIT:-$DEFAULT_COMMIT}"

PORT="${PORT:-8000}"
HOST="${HOST:-0.0.0.0}"
DEFAULT_FOLDER="${DEFAULT_FOLDER:-$PWD}"
CONNECTION_TOKEN="${CONNECTION_TOKEN:-}"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/web-vscode"
VSCODE_CLI_DIR="${VSCODE_CLI_DIR:-$DATA_HOME/cli}"
VSCODE_CLI_DATA_DIR="${VSCODE_CLI_DATA_DIR:-$VSCODE_CLI_DIR/data}"
VSCODE_DATA_DIR="${VSCODE_DATA_DIR:-$DATA_HOME/server-data}"

log() { printf '[serve-local] %s\n' "$*" >&2; }
die() { printf '[serve-local] ERROR: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      sed -n '2,48p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

case "$(uname -m)" in
  x86_64|amd64)  CLI_ARCH="linux-x64" ;;
  aarch64|arm64) CLI_ARCH="linux-arm64" ;;
  *) die "unsupported architecture '$(uname -m)' (supported: x86_64, aarch64)" ;;
esac

command -v curl >/dev/null || die "curl is required"
command -v tar  >/dev/null || die "tar is required"

mkdir -p "$VSCODE_CLI_DIR" "$VSCODE_CLI_DATA_DIR" "$VSCODE_DATA_DIR"

CLI="$VSCODE_CLI_DIR/code"
if [[ ! -x "$CLI" ]]; then
  log "downloading VS Code CLI (${VSCODE_COMMIT:0:7}) for ${CLI_ARCH}..."
  URL="https://update.code.visualstudio.com/commit:${VSCODE_COMMIT}/cli-${CLI_ARCH}/stable"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/vscode-cli.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/vscode_cli.tar.gz" "$URL"
  tar -xzf "$tmp/vscode_cli.tar.gz" -C "$VSCODE_CLI_DIR"
  [[ -x "$CLI" ]] || die "VS Code CLI extraction failed (expected $CLI)"
  trap - EXIT
  rm -rf "$tmp"
fi

log "CLI:      $("$CLI" --version | head -n1) (commit $VSCODE_COMMIT)"
log "host:     $HOST:$PORT"
log "folder:   $DEFAULT_FOLDER"
log "cache:    $VSCODE_CLI_DATA_DIR"
log "data:     $VSCODE_DATA_DIR"

args=(
  --cli-data-dir "$VSCODE_CLI_DATA_DIR"
  serve-web
  --host "$HOST"
  --port "$PORT"
  --commit-id "$VSCODE_COMMIT"
  --accept-server-license-terms
  --disable-telemetry
  --server-data-dir "$VSCODE_DATA_DIR"
  --default-folder "$DEFAULT_FOLDER"
)

if [[ -n "$CONNECTION_TOKEN" ]]; then
  args+=(--connection-token "$CONNECTION_TOKEN")
else
  args+=(--without-connection-token)
fi

args+=("$@")

log "starting code serve-web (first launch downloads the web server, ~270 MB)..."
exec "$CLI" "${args[@]}"
