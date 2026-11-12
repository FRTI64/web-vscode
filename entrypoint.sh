#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# entrypoint.sh — container entrypoint for the web-vscode image.
#
# Configures Microsoft's `code serve-web` and execs it (so it replaces this
# shell and receives signals from tini directly). The web server bundle is
# baked into the image, so the browser gets the workbench without a runtime
# download; the CLI cache path below must match the one warmed at build time.
#
# Environment:
#   HOST                 address to bind                  (default: 0.0.0.0)
#   PORT                 TCP port to listen on            (default: 8000)
#   VSCODE_COMMIT        VS Code commit to serve          (default: baked-in commit)
#   COMMIT               alias for VSCODE_COMMIT
#   CONNECTION_TOKEN     if non-empty, require ?tkn=<token>/cookie auth;
#                        if empty, run with --without-connection-token (open access)
#   DEFAULT_FOLDER       folder opened on first browser connect (default: /workspace)
#   SERVER_DATA_DIR      VS Code Server user data dir     (default: $HOME/.vscode-serve-web-data)
#   VSCODE_CLI_DATA_DIR  CLI metadata + server cache dir  (default: $HOME/.vscode/cli)
#   CODE_BIN             path to the `code` CLI           (default: /usr/local/bin/code)
#
# Usage:
#   docker run IMAGE                          # start VS Code web with defaults
#   docker run IMAGE --server-base-path /code # extra serve-web args are appended
#   docker run IMAGE code --version           # run an arbitrary command instead
#   docker run IMAGE bash                     # debug shell inside the image
#
# Extra serve-web arguments are appended verbatim; use the environment
# variables above for the options this script already sets.
# ---------------------------------------------------------------------------
set -euo pipefail

readonly BAKED_COMMIT="69047191fc427f2f92828279aae1d90d8eeda7ab"
readonly CODE_BIN="${CODE_BIN:-/usr/local/bin/code}"
readonly HOST="${HOST:-0.0.0.0}"
readonly PORT="${PORT:-8000}"
readonly COMMIT="${COMMIT:-${VSCODE_COMMIT:-$BAKED_COMMIT}}"
readonly CONNECTION_TOKEN="${CONNECTION_TOKEN:-}"
readonly DEFAULT_FOLDER="${DEFAULT_FOLDER:-/workspace}"
readonly HOME_DIR="${HOME:-/home/coder}"
readonly SERVER_DATA_DIR="${SERVER_DATA_DIR:-${HOME_DIR}/.vscode-serve-web-data}"
readonly CLI_DATA_DIR="${VSCODE_CLI_DATA_DIR:-${HOME_DIR}/.vscode/cli}"

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Returns 0 when the given long flag is present in the remaining arguments.
has_flag() {
    local flag="$1" arg
    shift
    for arg in "$@"; do
        [ "$arg" = "$flag" ] && return 0
    done
    return 1
}

extra_args=()
if [ "$#" -gt 0 ]; then
    case "$1" in
        -*)
            # `docker run IMAGE --some-serve-web-flag`: append as extra args.
            extra_args=("$@")
            ;;
        serve-web)
            # Allow `docker run IMAGE serve-web [flags]` as an explicit spelling.
            shift
            extra_args=("$@")
            ;;
        *)
            # `docker run IMAGE <command> [args...]`: passthrough.
            log "executing: $*"
            exec "$@"
            ;;
    esac
fi

case "$PORT" in
    '' | *[!0-9]*) die "PORT must be an integer, got '$PORT'" ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    die "PORT must be between 1 and 65535, got '$PORT'"
fi

[ -x "$CODE_BIN" ] || die "VS Code CLI not found or not executable at '$CODE_BIN'"
if ! mkdir -p "$SERVER_DATA_DIR"; then
    die "cannot create SERVER_DATA_DIR '$SERVER_DATA_DIR' (check volume ownership)"
fi
if [ ! -d "${CLI_DATA_DIR}/serve-web/${COMMIT}" ]; then
    log "WARNING: VS Code ${COMMIT} is not in the baked cache (${CLI_DATA_DIR}/serve-web/${COMMIT});"
    log "WARNING: the first browser request will download ~270 MB from Microsoft."
fi

args=(--cli-data-dir "$CLI_DATA_DIR" serve-web)

# Defaults; a flag supplied by the caller wins so the CLI does not reject
# duplicated arguments.
has_flag --host "${extra_args[@]}" || args+=(--host "$HOST")
has_flag --port "${extra_args[@]}" || args+=(--port "$PORT")
has_flag --commit-id "${extra_args[@]}" || args+=(--commit-id "$COMMIT")
has_flag --server-data-dir "${extra_args[@]}" || args+=(--server-data-dir "$SERVER_DATA_DIR")
has_flag --accept-server-license-terms "${extra_args[@]}" || args+=(--accept-server-license-terms)
has_flag --disable-telemetry "${extra_args[@]}" || args+=(--disable-telemetry)
if [ -n "$DEFAULT_FOLDER" ] && ! has_flag --default-folder "${extra_args[@]}"; then
    args+=(--default-folder "$DEFAULT_FOLDER")
fi

if has_flag --connection-token "${extra_args[@]}" \
    || has_flag --connection-token-file "${extra_args[@]}" \
    || has_flag --without-connection-token "${extra_args[@]}"; then
    : # authentication was configured explicitly by the caller
elif [ -n "$CONNECTION_TOKEN" ]; then
    args+=(--connection-token "$CONNECTION_TOKEN")
else
    args+=(--without-connection-token)
fi

args+=("${extra_args[@]}")

if [ -n "$CONNECTION_TOKEN" ]; then
    log "VS Code ${COMMIT}: http://${HOST}:${PORT} (connection token enabled)"
else
    log "VS Code ${COMMIT}: http://${HOST}:${PORT} (no connection token: open access)"
fi
log "workspace: ${DEFAULT_FOLDER}, server data: ${SERVER_DATA_DIR}, cache: ${CLI_DATA_DIR}"

exec "$CODE_BIN" "${args[@]}"
