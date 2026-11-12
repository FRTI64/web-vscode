# ---------------------------------------------------------------------------
# web-vscode — browser-accessible Visual Studio Code on top of `code serve-web`.
#
# Build:
#   docker build -t ghcr.io/frti64/web-vscode .
# Run:
#   docker run --rm -p 8000:8000 -v "$PWD/workspace:/workspace" \
#     ghcr.io/frti64/web-vscode:latest
# Browser:
#   http://localhost:8000
#
# The pinned VS Code CLI and the matching web server bundle are baked into the
# image at build time. The CLI downloads the web server on the first
# `serve-web` start into $VSCODE_CLI_DATA_DIR/serve-web/<commit>, so a warm-up
# run during the build hydrates that cache and containers start without having
# to download ~270 MB from Microsoft. See README.md for the full contract.
# ---------------------------------------------------------------------------
ARG VSCODE_VERSION=1.146.0
ARG VSCODE_COMMIT=69047191fc427f2f92828279aae1d90d8eeda7ab

FROM debian:bookworm-slim

ARG VSCODE_VERSION
ARG VSCODE_COMMIT

LABEL org.opencontainers.image.title="web-vscode" \
      org.opencontainers.image.description="Browser-accessible Visual Studio Code (code serve-web)" \
      org.opencontainers.image.url="https://github.com/FRTI64/web-vscode" \
      org.opencontainers.image.source="https://github.com/FRTI64/web-vscode" \
      org.opencontainers.image.version="${VSCODE_VERSION}" \
      org.opencontainers.image.revision="${VSCODE_COMMIT}" \
      org.opencontainers.image.licenses="MIT"

# Runtime contract shared with entrypoint.sh and the CI smoke test:
#   VSCODE_CLI_DATA_DIR must match the cache hydrated by the warm-up step.
#   HOME, PORT, DEFAULT_FOLDER are the runtime defaults documented in README.md.
ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/coder \
    VSCODE_CLI_DATA_DIR=/home/coder/.vscode/cli \
    VSCODE_COMMIT=${VSCODE_COMMIT} \
    PORT=8000 \
    DEFAULT_FOLDER=/workspace

# `-o pipefail` for the pipelines below (e.g. the `code --version | grep`
# checks); bash is already present in the Debian base image.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# One layer for the system prerequisites, the non-root user, and the pinned
# CLI. ca-certificates/curl are needed to download VS Code; libstdc++6 and
# ca-certificates are required by the bundled Node.js runtime of the web
# server, and git powers VS Code's source control features.
#
# Debian package versions are intentionally not pinned: the base image tag
# pins the distribution, and exact pinning would block security updates.
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl git libstdc++6 tini; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --gid 1000 coder; \
    useradd --uid 1000 --gid coder --create-home --home-dir /home/coder --shell /bin/bash coder; \
    install -d -m 0755 /workspace; \
    install -d -m 0700 -o coder -g coder /run/user/1000; \
    install -d -m 0755 -o coder -g coder \
        /home/coder/.vscode \
        /home/coder/.vscode/cli \
        /home/coder/.vscode-serve-web-data; \
    url="https://update.code.visualstudio.com/commit:${VSCODE_COMMIT}/cli-linux-x64/stable"; \
    tmpdir="$(mktemp -d)"; \
    curl -fsSL --retry 3 --retry-delay 2 -o "$tmpdir/vscode_cli.tar.gz" "$url"; \
    tar -xzf "$tmpdir/vscode_cli.tar.gz" -C "$tmpdir"; \
    test -x "$tmpdir/code"; \
    install -m 0755 "$tmpdir/code" /usr/local/bin/code; \
    rm -rf "$tmpdir"; \
    chown -R coder:coder /home/coder /workspace /run/user/1000; \
    cli_version="$(HOME=/tmp VSCODE_CLI_DATA_DIR=/tmp/vscode-cli-check code --version)"; \
    printf 'VS Code CLI version output:\n%s\n' "$cli_version"; \
    printf '%s\n' "$cli_version" | grep -Fq "${VSCODE_VERSION}"; \
    printf '%s\n' "$cli_version" | grep -Fq "${VSCODE_COMMIT}"; \
    rm -rf /tmp/vscode-cli-check

COPY --chown=coder:coder --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# The runtime contract (README, CI smoke test) names the user "coder"; the
# account is created with a fixed uid/gid of 1000 just above.
# hadolint ignore=DL3066
USER coder

# Warm the serve-web cache so the VS Code web server is inside the image.
# `code serve-web` fetches the web server bundle for the pinned commit into
# $VSCODE_CLI_DATA_DIR/serve-web/<commit>; the first HTTP 200 confirms the
# bundle is complete and runnable, then the process is stopped again. The
# build fails if the cache cannot be warmed.
#
# `kill` only stops the temporary build-time server; this is not a container
# init script, so DL3001 does not apply.
# hadolint ignore=DL3001
RUN set -eux; \
    port=18080; \
    cache="${VSCODE_CLI_DATA_DIR}/serve-web/${VSCODE_COMMIT}"; \
    logfile=/tmp/serve-web-warm.log; \
    code serve-web \
        --host 127.0.0.1 \
        --port "$port" \
        --without-connection-token \
        --accept-server-license-terms \
        --disable-telemetry \
        --commit-id "${VSCODE_COMMIT}" \
        --server-data-dir "$HOME/.vscode-serve-web-data" \
        >"$logfile" 2>&1 & \
    server_pid=$!; \
    ready=0; \
    for _ in {1..450}; do \
        if ! kill -0 "$server_pid" 2>/dev/null; then \
            echo "ERROR: code serve-web exited before the VS Code web server cache was warmed"; \
            cat "$logfile"; \
            exit 1; \
        fi; \
        http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${port}/" || true)"; \
        if [ "$http_code" = "200" ] && [ -x "$cache/bin/code-server" ]; then \
            ready=1; \
            break; \
        fi; \
        if grep -q "Server bound to" "$logfile" 2>/dev/null && [ -x "$cache/bin/code-server" ]; then \
            ready=1; \
            break; \
        fi; \
        sleep 2; \
    done; \
    if [ "$ready" -ne 1 ]; then \
        echo "ERROR: timed out after 15 min waiting for the VS Code web server cache to be warmed"; \
        cat "$logfile"; \
        exit 1; \
    fi; \
    kill -TERM "$server_pid" 2>/dev/null || true; \
    for _ in {1..30}; do \
        kill -0 "$server_pid" 2>/dev/null || break; \
        sleep 1; \
    done; \
    kill -KILL "$server_pid" 2>/dev/null || true; \
    wait "$server_pid" 2>/dev/null || true; \
    test -x "$cache/bin/code-server"; \
    rm -f "$logfile"; \
    echo "Warmed VS Code ${VSCODE_COMMIT} web server cache at ${cache}"

EXPOSE 8000

# The workbench answers HTTP 200 on `/` once the (pre-warmed) server is up.
# Shell form is required so ${PORT} is expanded from the container environment
# at runtime; the JSON notation would hardcode port 8000.
# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT:-8000}/" >/dev/null || exit 1

# tini reaps zombies and forwards signals; the entrypoint configures and execs
# `code serve-web` as PID 1's child so `docker stop` shuts the server down.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
