#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# serve.sh — run the web-vscode container as a WebAssembly image in the
# browser, served from this directory.
#
#   ./scripts/serve.sh
#   open http://localhost:8091/        (first boot takes ~8-10 minutes)
#
# What it does:
#   1. makes sure the `c2w --to-js` artifact is present (downloads the GitHub
#      Actions artifact from FRTI64/frti64_c2w if `gh` is available),
#   2. copies the auto-loader page (../web) next to the artifact files,
#   3. starts `c2w-net`, the host-side network stack that bridges the wasm
#      container's virtual network to the host and forwards guest :8000 to
#      host :18080,
#   4. starts a small Node server that serves the page (+ COOP/COEP headers so
#      the QEMU-Wasm runtime can use SharedArrayBuffer) and reverse-proxies
#      `/vs/` to the container's VS Code server.
#
# Environment:
#   PAGE_PORT      page/static server port              (default: 8091)
#   GUEST_PORT     host port forwarded to guest :8000   (default: 18080)
#   WS_PORT        c2w-net WebSocket port used by the wasm container (8888)
#   IMAGE_DIR      directory with out.js/.wasm/.data    (default: <repo>/htdocs)
#   MEMORY         load artifacts into RAM and serve from memory (default: 1)
#   COMPRESS_DATA  gzip the big files for the wire, decompress in browser
#                  (default: 1; reduces the initial download ~3x)
#   STATIC_CACHE   optional local copy of the VS Code web-server files
#                  (default: <repo>/.cache/serve-web/<commit>; see
#                  scripts/fetch-static-cache.sh — makes the workbench load
#                  much faster by serving client assets from the host)
#   C2W_NET        path to the c2w-net binary (default: <repo>/.bin/c2w-net,
#                  auto-downloaded from the container2wasm release)
#   ARTIFACT_RUN   optional GitHub Actions run id to download the artifact from
#   SKIP_DOWNLOAD  set to 1 to fail instead of downloading the artifact
#
# Requirements: Linux x86_64/arm64, node >= 18, curl+tar, network for the
# first artifact download. c2w-net is only tested on Linux.
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WEBSRC="$ROOT/web"
IMAGE_DIR=${IMAGE_DIR:-$ROOT/htdocs}
PAGE_PORT=${PAGE_PORT:-8091}
GUEST_PORT=${GUEST_PORT:-18080}
WS_PORT=${WS_PORT:-8888}
SKIP_DOWNLOAD=${SKIP_DOWNLOAD:-0}

C2W_COMMIT="69047191fc427f2f92828279aae1d90d8eeda7ab"
STATIC_CACHE=${STATIC_CACHE:-$ROOT/.cache/serve-web/$C2W_COMMIT}
ARTIFACT_REPO=${ARTIFACT_REPO:-FRTI64/frti64_c2w}
ARTIFACT_NAME=${ARTIFACT_NAME:-c2w-web-vscode-wasm}
MEMORY=${MEMORY:-1}
COMPRESS_DATA=${COMPRESS_DATA:-1}

log() { printf '[wasm-demo] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

for tool in node tar curl; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required"
done

mkdir -p "$IMAGE_DIR"

# ---------------------------------------------------------------------------
# 1. c2w --to-js artifact (out.js, load.js, arg-module.js, qemu-system-*.data/.wasm)
# ---------------------------------------------------------------------------
artifact_missing() {
  for f in out.js load.js arg-module.js qemu-system-x86_64.wasm qemu-system-x86_64.data; do
    [ -f "$IMAGE_DIR/$f" ] || return 0
  done
  return 1
}

download_artifact() {
  command -v gh >/dev/null 2>&1 || die "artifact missing and 'gh' is not installed; download the '$ARTIFACT_NAME' artifact from GitHub Actions into $IMAGE_DIR"
  local tmp run_id
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/c2w-artifact.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  if [ -n "${ARTIFACT_RUN:-}" ]; then
    run_id="$ARTIFACT_RUN"
  else
    run_id=$(gh api "repos/$ARTIFACT_REPO/actions/artifacts?name=$ARTIFACT_NAME&per_page=100" \
      --jq '[.artifacts[] | select(.expired == false)] | sort_by(.created_at) | reverse | .[0].workflow_run.id' 2>/dev/null || true)
    [ -n "$run_id" ] && [ "$run_id" != "null" ] || die "no unexpired '$ARTIFACT_NAME' artifact found in $ARTIFACT_REPO"
  fi
  log "downloading artifact '$ARTIFACT_NAME' from run $run_id ($ARTIFACT_REPO)..."
  gh run download "$run_id" -R "$ARTIFACT_REPO" -n "$ARTIFACT_NAME" -D "$tmp"
  cp -f "$tmp"/* "$IMAGE_DIR"/
  rm -rf "$tmp"
  trap - EXIT
}

if artifact_missing; then
  [ "$SKIP_DOWNLOAD" = "1" ] && die "artifact files are missing in $IMAGE_DIR (SKIP_DOWNLOAD=1)"
  log "artifact files missing, trying GitHub Actions..."
  download_artifact
  artifact_missing && die "artifact download did not provide the expected files"
fi
log "artifact: $IMAGE_DIR ($(du -sh "$IMAGE_DIR" | cut -f1))"

# ---------------------------------------------------------------------------
# 2. page assets
# ---------------------------------------------------------------------------
cp -R "$WEBSRC"/. "$IMAGE_DIR"/
log "page assets copied to $IMAGE_DIR"

# ---------------------------------------------------------------------------
# 3. c2w-net (host-side network stack for the wasm container)
# ---------------------------------------------------------------------------
find_c2w_net() {
  [ -n "${C2W_NET:-}" ] && [ -x "$C2W_NET" ] && { echo "$C2W_NET"; return; }
  [ -x "$ROOT/.bin/c2w-net" ] && { echo "$ROOT/.bin/c2w-net"; return; }
  command -v c2w-net 2>/dev/null || true
}

C2W_NET_BIN=$(find_c2w_net)
if [ -z "$C2W_NET_BIN" ]; then
  case "$(uname -m)" in
    x86_64|amd64) C2W_ARCH=linux-amd64 ;;
    aarch64|arm64) C2W_ARCH=linux-arm64 ;;
    *) die "unsupported architecture for c2w-net: $(uname -m)" ;;
  esac
  mkdir -p "$ROOT/.bin"
  url="https://github.com/container2wasm/container2wasm/releases/download/v0.8.5/container2wasm-v0.8.5-${C2W_ARCH}.tar.gz"
  log "downloading c2w-net from $url ..."
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/c2w-net.XXXXXX")
  curl -fsSL --retry 3 -o "$tmp/c2w.tar.gz" "$url"
  tar -xzf "$tmp/c2w.tar.gz" -C "$tmp" c2w-net 2>/dev/null || tar -xzf "$tmp/c2w.tar.gz" -C "$tmp" "./c2w-net" 2>/dev/null || tar -xzf "$tmp/c2w.tar.gz" -C "$tmp"
  found=$(find "$tmp" -maxdepth 2 -name c2w-net -type f | head -n1)
  [ -n "$found" ] || die "c2w-net not found in the release archive"
  install -m 0755 "$found" "$ROOT/.bin/c2w-net"
  rm -rf "$tmp"
  C2W_NET_BIN="$ROOT/.bin/c2w-net"
fi
log "c2w-net: $C2W_NET_BIN"

# ---------------------------------------------------------------------------
# 4. start helper processes
# ---------------------------------------------------------------------------
server_args=(--root "$IMAGE_DIR" --port "$PAGE_PORT" --guest-port "$GUEST_PORT")
[ "$MEMORY" = "1" ] && server_args+=(--memory)
[ "$COMPRESS_DATA" = "1" ] && server_args+=(--compress-data)
if [ -f "$STATIC_CACHE/product.json" ]; then
  server_args+=(--static-cache "$STATIC_CACHE")
  log "static asset cache: $STATIC_CACHE (VS Code client loads from host)"
else
  log "no static asset cache at $STATIC_CACHE — VS Code client assets will be served"
  log "  through the emulated guest and load much slower. Run"
  log "  ./scripts/fetch-static-cache.sh (or ./scripts/fetch-openvscode-cache.sh) once."
fi

PIDS=()
cleanup() {
  trap - INT TERM EXIT
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# NOTE: Go's flag parsing stops at the first positional argument, so all flags
# (-p, --listen-ws) MUST come before the WebSocket listen address.
"$C2W_NET_BIN" -p "${GUEST_PORT}:8000" --listen-ws "127.0.0.1:${WS_PORT}" \
  >"$ROOT/c2w-net.log" 2>&1 &
PIDS+=($!)
log "c2w-net: ws://127.0.0.1:${WS_PORT}  (forward :${GUEST_PORT} -> guest :8000)"

node "$ROOT/web/server.mjs" "${server_args[@]}" >"$ROOT/server.log" 2>&1 &
PIDS+=($!)
sleep 1
kill -0 "${PIDS[(-1)]}" 2>/dev/null || die "web server failed to start (see $ROOT/server.log)"
PAGE_QUERY="?net=delegate=ws://127.0.0.1:${WS_PORT}&port=${GUEST_PORT}"
log "page server: http://localhost:${PAGE_PORT}/${PAGE_QUERY}"
echo
echo "  打开页面：      http://localhost:${PAGE_PORT}/${PAGE_QUERY}"
echo "  直接访问 VS Code（服务就绪后）： http://localhost:${GUEST_PORT}/"
echo "  模式：${MEMORY:+in-memory }${COMPRESS_DATA:++ gzip wire compression}"
echo "  首次启动需要在浏览器里引导 wasm 容器，几分钟（取决于镜像大小）。按 Ctrl-C 停止。"
echo

wait
