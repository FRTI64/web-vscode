#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ci-smoke.sh — run the built web-vscode image and prove it actually serves
# the VS Code web workbench.
#
# Used by .github/workflows/build.yml after the image build step.
#
# The script:
#   1. resolves the primary image tag from the docker/metadata-action "tags"
#      output (first non-empty line),
#   2. pulls it (push runs) or uses the locally loaded image (pull_request runs,
#      where the image was never published),
#   3. starts the image detached with 8000:8000 published,
#   4. polls until the web server answers HTTP 200 (VS Code's serve-web may
#      briefly answer 202 while the pre-warmed server starts; allow 180s),
#   5. asserts: HTTP 200, Content-Type text/html, body contains "vscode"
#      (case-insensitive), and the container runs as non-root uid 1000,
#   6. always removes the container, dumping docker logs on failure.
#
# Required environment:
#   IMAGE_TAGS       newline-separated image references (docker/metadata-action
#                    `tags` output); the first line is treated as primary.
#
# Optional environment:
#   PULL_IMAGE       "true" (default): pull the primary tag (push runs).
#                    "false": require the image to be present locally (PR runs).
#   CONTAINER_NAME   container name (default: web-vscode-ci-smoke)
#   HOST_PORT        host port to publish (default: 8000 -> maps 8000:8000)
#   SERVICE_PORT     container port to publish (default: 8000)
#   STARTUP_TIMEOUT  seconds to wait for HTTP 200 (default: 180)
#   POLL_INTERVAL    seconds between readiness polls (default: 2)
#
# Exit codes: 0 = healthy image, 1 = any assertion/timeout failure.
# ---------------------------------------------------------------------------
set -euo pipefail

IMAGE_TAGS="${IMAGE_TAGS:-}"
PULL_IMAGE="${PULL_IMAGE:-true}"
CONTAINER_NAME="${CONTAINER_NAME:-web-vscode-ci-smoke}"
HOST_PORT="${HOST_PORT:-8000}"
SERVICE_PORT="${SERVICE_PORT:-8000}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-180}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"

log() { printf '[ci-smoke] %s\n' "$*"; }
die() { printf '[ci-smoke] ERROR: %s\n' "$*" >&2; exit 1; }

for var in HOST_PORT SERVICE_PORT STARTUP_TIMEOUT POLL_INTERVAL; do
  [[ "${!var}" =~ ^[0-9]+$ ]] || die "$var must be a non-negative integer (got '${!var}')"
done
(( HOST_PORT > 0 && HOST_PORT <= 65535 )) || die "HOST_PORT out of range: $HOST_PORT"
(( SERVICE_PORT > 0 && SERVICE_PORT <= 65535 )) || die "SERVICE_PORT out of range: $SERVICE_PORT"
(( STARTUP_TIMEOUT > 0 )) || die "STARTUP_TIMEOUT must be > 0"
(( POLL_INTERVAL > 0 )) || die "POLL_INTERVAL must be > 0"
case "$PULL_IMAGE" in
  true|false) ;;
  *) die "PULL_IMAGE must be 'true' or 'false' (got '$PULL_IMAGE')" ;;
esac

for tool in docker curl; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but not found in PATH"
done
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"

# --- resolve the primary image reference from metadata-action output --------
[[ -n "$IMAGE_TAGS" ]] || die "IMAGE_TAGS is not set (pass docker/metadata-action 'tags' output)"
IMAGE_REF="$(printf '%s\n' "$IMAGE_TAGS" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | head -n 1)"
[[ -n "$IMAGE_REF" ]] || die "could not resolve a primary image tag from IMAGE_TAGS"
TMP_DIR="$(mktemp -d)"

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

container_is_running() {
  docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -qx 'true'
}

dump_container_logs() {
  log "---- container state/logs (helps diagnosing startup failures) ----"
  docker inspect --format 'state={{.State.Status}} exit={{.State.ExitCode}} started={{.State.StartedAt}}' \
    "$CONTAINER_NAME" 2>/dev/null || true
  docker logs "$CONTAINER_NAME" 2>&1 | tail -n 100 || true
  log "------------------------------------------------------------------"
}

# --- make the image available locally --------------------------------------
if [[ "$PULL_IMAGE" == "true" ]]; then
  log "Pulling pushed image: $IMAGE_REF"
  docker pull "$IMAGE_REF" || die "docker pull failed for $IMAGE_REF"
else
  log "Using locally loaded image (pull_request build): $IMAGE_REF"
  docker image inspect "$IMAGE_REF" >/dev/null 2>&1 \
    || die "image $IMAGE_REF is not present locally and PULL_IMAGE=false"
fi

CONFIG_USER="$(docker image inspect --format '{{.Config.User}}' "$IMAGE_REF")"
log "Image config: user='${CONFIG_USER:-<unset/root default>}'"

# --- start the container (port 8000:8000 by default) -----------------------
log "Starting container '$CONTAINER_NAME' from $IMAGE_REF (${HOST_PORT}:${SERVICE_PORT})"
docker run -d --name "$CONTAINER_NAME" \
  -p "${HOST_PORT}:${SERVICE_PORT}" \
  "$IMAGE_REF" >/dev/null || die "failed to start container from $IMAGE_REF"

URL="http://127.0.0.1:${HOST_PORT}/"
BODY_FILE="$TMP_DIR/body.html"
HEADERS_FILE="$TMP_DIR/headers.txt"
deadline=$(( SECONDS + STARTUP_TIMEOUT ))
last_status="none"
ready="false"

log "Polling $URL for HTTP 200 (timeout ${STARTUP_TIMEOUT}s, interval ${POLL_INTERVAL}s)"
while (( SECONDS < deadline )); do
  code="$(curl -sS -o "$BODY_FILE" -D "$HEADERS_FILE" -w '%{http_code}' \
    --connect-timeout 5 --max-time 15 "$URL" 2>/dev/null)" || code="000"
  last_status="${code:-curl-error}"
  if [[ "$last_status" == "200" ]]; then
    ready="true"
    break
  fi
  if ! container_is_running; then
    dump_container_logs
    die "container '$CONTAINER_NAME' exited before serving HTTP 200"
  fi
  log "not ready yet: HTTP ${last_status} (${SECONDS}s elapsed)"
  sleep "$POLL_INTERVAL"
done

if [[ "$ready" != "true" ]]; then
  dump_container_logs
  die "timed out after ${STARTUP_TIMEOUT}s waiting for HTTP 200 from $URL (last status: $last_status)"
fi

# --- strict assertions on the served page ----------------------------------
final_code="$(curl -fsS -o "$BODY_FILE" -D "$HEADERS_FILE" -w '%{http_code}' \
  --connect-timeout 5 --max-time 15 "$URL")" || die "final curl to $URL failed"
[[ "$final_code" == "200" ]] || die "expected HTTP 200 from $URL, got $final_code"

grep -qiE '^content-type:[[:space:]]*text/html' "$HEADERS_FILE" \
  || die "expected Content-Type text/html from $URL, got: $(grep -i '^content-type:' "$HEADERS_FILE" || echo '<none>')"

grep -qi 'vscode' "$BODY_FILE" \
  || die "response body does not look like the VS Code web workbench (no 'vscode' marker)"

# --- non-root uid 1000 contract --------------------------------------------
container_is_running || die "container '$CONTAINER_NAME' is not running anymore"
runtime_uid="$(docker exec "$CONTAINER_NAME" id -u)" \
  || die "could not run 'id -u' inside the container"
[[ "$runtime_uid" == "1000" ]] \
  || die "container does not run as uid 1000 (got '$runtime_uid'; Config.User='${CONFIG_USER:-<unset>}')"
runtime_user="$(docker exec "$CONTAINER_NAME" id -un 2>/dev/null || true)"
log "Container process identity: ${runtime_user:-unknown} (uid ${runtime_uid}), non-root OK"

# --- pass ----------------------------------------------------------------
image_id="$(docker image inspect --format '{{.Id}}' "$IMAGE_REF")"
content_type="$(grep -i '^content-type:' "$HEADERS_FILE" | head -n 1 | sed 's/^[^:]*:[[:space:]]*//;s/\r$//')"
log "PASS: image is built correctly and serves VS Code web"
log "  image:        $IMAGE_REF"
log "  image id:     $image_id"
log "  config user:  ${CONFIG_USER:-<unset>}"
log "  runtime user: ${runtime_user:-unknown} (uid ${runtime_uid})"
log "  url:          $URL"
log "  http status:  $final_code"
log "  content-type: ${content_type:-<none>}"
log "  body marker:  vscode"
