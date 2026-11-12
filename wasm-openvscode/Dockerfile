# ---------------------------------------------------------------------------
# Minimal OpenVSCode Server image for the container2wasm (--to-js) build.
#
# Goal: keep the guest root filesystem as small as possible so the browser has
# to download/keep little in memory, and replace the Microsoft VS Code CLI
# wrapper with a direct node server start (faster boot inside QEMU).
#
#   image size  : ~100 MB compressed (debian-slim + OpenVSCode Server tarball)
#   runtime     : /opt/openvscode/bin/openvscode-server --host 0.0.0.0 --port 8000
#   writable    : $HOME, server data and workspace live under /tmp (RAM in the
#                 wasm guest); nothing is persisted to disk.
# ---------------------------------------------------------------------------
ARG OVS_VERSION=1.109.5

FROM debian:bookworm-slim

ARG OVS_VERSION

LABEL org.opencontainers.image.title="web-vscode-openvscode" \
      org.opencontainers.image.description="Minimal OpenVSCode Server image for running VS Code in the browser via container2wasm" \
      org.opencontainers.image.url="https://github.com/FRTI64/web-vscode" \
      org.opencontainers.image.source="https://github.com/FRTI64/web-vscode" \
      org.opencontainers.image.version="${OVS_VERSION}" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/tmp/home \
    PORT=8000 \
    HOST=0.0.0.0 \
    SERVER_DATA_DIR=/tmp/openvscode-data \
    DEFAULT_FOLDER=/tmp/workspace \
    TMPDIR=/tmp/coder-tmp

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
# One layer for OS prerequisites + the OpenVSCode Server tarball. The tarball
# is extracted (and *.map files are pruned) in the same RUN so the final layer
# contains only the pruned tree.
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl libstdc++6 tini; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --gid 1000 coder; \
    useradd --uid 1000 --gid coder --no-create-home --home-dir /tmp/home --shell /bin/bash coder; \
    install -d -m 0755 /opt/openvscode; \
    url="https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v${OVS_VERSION}/openvscode-server-v${OVS_VERSION}-linux-x64.tar.gz"; \
    curl -fsSL --retry 3 --retry-delay 2 -o /tmp/ovs.tar.gz "$url"; \
    tar -xzf /tmp/ovs.tar.gz -C /opt/openvscode --strip-components=1; \
    rm -f /tmp/ovs.tar.gz; \
    test -x /opt/openvscode/bin/openvscode-server; \
    find /opt/openvscode -name '*.map' -delete

COPY --chown=coder:coder --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# hadolint ignore=DL3066
USER coder
WORKDIR /tmp/workspace
EXPOSE 8000

# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=5s --start-period=35s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT:-8000}/" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
