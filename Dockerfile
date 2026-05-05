FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie@sha256:b3c543b6c4f23a5f2df22866bd7857e5d304b67a564f4feab6ac22044dde719b AS uv_source
FROM tianon/gosu:1.19-trixie@sha256:3b176695959c71e123eb390d427efc665eeb561b1540e82679c15e992006b8b9 AS gosu_source

# ---------- Ops tools (kubectl, gh) baked at build time ----------
# The kvncrw homelab agent chart used to fetch these from GitHub at every
# pod boot, which made startup depend on github.com being reachable and
# rate-friendly. Pin and pre-install instead.
FROM alpine:3.20 AS ops_tools
ARG KUBECTL_VERSION=v1.35.3
ARG GH_VERSION=2.91.0
RUN apk add --no-cache curl tar
WORKDIR /out
RUN set -eu; \
    arch=$(uname -m); \
    case "$arch" in \
      x86_64)  go_arch=amd64 ;; \
      aarch64) go_arch=arm64 ;; \
      *) echo "unsupported arch $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${go_arch}/kubectl" -o kubectl; \
    chmod 0755 kubectl; \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${go_arch}.tar.gz" \
      | tar -xz; \
    cp "gh_${GH_VERSION}_linux_${go_arch}/bin/gh" gh; \
    chmod 0755 gh; \
    rm -rf "gh_${GH_VERSION}_linux_${go_arch}"

# ---------- capbroker binary + cap-* wrappers baked at build time ----------
FROM golang:1.26-alpine AS capbroker_builder
ARG CAPBROKER_REPO=https://github.com/kvncrw/capbroker.git
ARG CAPBROKER_REF=7c65284
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --filter=blob:none "${CAPBROKER_REPO}" . && git checkout "${CAPBROKER_REF}"
RUN CGO_ENABLED=0 go build -trimpath -o /out/capbroker .
RUN cp -R scripts /out/scripts

FROM debian:13.4

# Disable Python stdout buffering to ensure logs are printed immediately
ENV PYTHONUNBUFFERED=1

# Store Playwright browsers outside the volume mount so the build-time
# install survives the /opt/data volume overlay at runtime.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

# Install system dependencies in one layer, clear APT cache
# tini reaps orphaned zombie processes (MCP stdio subprocesses, git, bun, etc.)
# that would otherwise accumulate when hermes runs as PID 1. See #15012.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential curl nodejs npm python3 ripgrep ffmpeg gcc python3-dev libffi-dev procps git openssh-client docker-cli tini jq && \
    rm -rf /var/lib/apt/lists/*

# Ops tools + capbroker baked at build time. Avoids per-pod-boot downloads
# and a Go compile from the homelab init containers.
COPY --from=ops_tools /out/kubectl /usr/local/bin/kubectl
COPY --from=ops_tools /out/gh /usr/local/bin/gh
COPY --from=capbroker_builder /out/capbroker /usr/local/bin/capbroker
COPY --from=capbroker_builder /out/scripts/cap-* /usr/local/bin/
RUN chmod 0755 /usr/local/bin/kubectl /usr/local/bin/gh /usr/local/bin/capbroker /usr/local/bin/cap-*

# Non-root user for runtime; UID can be overridden via HERMES_UID at runtime
RUN useradd -u 10000 -m -d /opt/data hermes

COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

WORKDIR /opt/hermes

# ---------- Layer-cached dependency install ----------
# Copy only package manifests first so npm install + Playwright are cached
# unless the lockfiles themselves change.
COPY package.json package-lock.json ./
COPY web/package.json web/package-lock.json web/
COPY ui-tui/package.json ui-tui/package-lock.json ui-tui/
COPY ui-tui/packages/hermes-ink/package.json ui-tui/packages/hermes-ink/package-lock.json ui-tui/packages/hermes-ink/

RUN npm install --prefer-offline --no-audit && \
    npx playwright install --with-deps chromium --only-shell && \
    (cd web && npm install --prefer-offline --no-audit) && \
    (cd ui-tui && npm install --prefer-offline --no-audit) && \
    npm cache clean --force

# ---------- Source code ----------
# .dockerignore excludes node_modules, so the installs above survive.
COPY --chown=hermes:hermes . .

# Build browser dashboard and terminal UI assets.
RUN cd web && npm run build && \
    cd ../ui-tui && npm run build && \
    rm -rf node_modules/@hermes/ink && \
    rm -rf packages/hermes-ink/node_modules && \
    cp -R packages/hermes-ink node_modules/@hermes/ink && \
    npm install --omit=dev --prefer-offline --no-audit --prefix node_modules/@hermes/ink && \
    rm -rf node_modules/@hermes/ink/node_modules/react && \
    node --input-type=module -e "await import('@hermes/ink')"

# ---------- Permissions ----------
# Make install dir world-readable so any HERMES_UID can read it at runtime.
# The venv needs to be traversable too.
USER root
RUN chmod -R a+rX /opt/hermes
# Start as root so the entrypoint can usermod/groupmod + gosu.
# If HERMES_UID is unset, the entrypoint drops to the default hermes user (10000).

# ---------- Python virtualenv ----------
RUN uv venv && \
    uv pip install --no-cache-dir -e ".[all]"

# ---------- Runtime ----------
ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
ENV HERMES_HOME=/opt/data
ENV PATH="/opt/data/.local/bin:${PATH}"
VOLUME [ "/opt/data" ]
ENTRYPOINT [ "/usr/bin/tini", "-g", "--", "/opt/hermes/docker/entrypoint.sh" ]
