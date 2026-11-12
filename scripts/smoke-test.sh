#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# smoke-test.sh — check that a `code serve-web` instance is really serving the
# VS Code workbench.
#
# The serve-web front-end answers 202 with a "downloading, please wait" page
# while the actual web server is being fetched/started, then starts returning
# the workbench HTML with 200.  This script polls until 200 + expected marker.
#
# Usage:
#   ./scripts/smoke-test.sh [--url URL] [--timeout SECONDS] [--expect TEXT]
#
# Defaults: http://127.0.0.1:8000, 300s, marker "vscode".
# Exit codes: 0 = healthy, 1 = timed out / wrong response.
# ---------------------------------------------------------------------------
set -euo pipefail

URL="http://127.0.0.1:8000"
TIMEOUT=300
EXPECT="vscode"

log() { printf '[smoke-test] %s\n' "$*" >&2; }
die() { printf '[smoke-test] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)     URL=${2:?}; shift 2 ;;
    --timeout) TIMEOUT=${2:?}; shift 2 ;;
    --expect)  EXPECT=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

command -v curl >/dev/null || die "curl is required"

deadline=$(( $(date +%s) + TIMEOUT ))
body="$(mktemp)"
trap 'rm -f "$body"' EXIT

last_status="none"
while :; do
  code=$(curl -sS -o "$body" -w '%{http_code}' --max-time 5 "$URL/" 2>/dev/null || true)
  last_status="${code:-curl-error}"
  if [[ "$code" == "200" ]] && grep -qi "$EXPECT" "$body"; then
    log "OK: $URL/ returned 200 and contains '$EXPECT' after $(( TIMEOUT - (deadline - $(date +%s)) ))s"
    head -c 300 "$body" | tr '\n' ' ' >&2; echo >&2
    exit 0
  fi
  if (( $(date +%s) >= deadline )); then
    die "timed out after ${TIMEOUT}s waiting for $URL/ (last HTTP status: $last_status, expected marker: '$EXPECT')"
  fi
  sleep 2
done
