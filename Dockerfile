# iPolloWork — full web UI + headless host in a single container, served from one origin.
#
# Build stage compiles the same React app the desktop client renders
# (@ipollowork/app) as a web deployment, plus the headless iPolloWork
# server and orchestrator from source (the published Dockerfile's
# `npm install -g ipollowork-orchestrator` target is not on the public registry).
#
# Runtime stage runs nginx (static SPA + reverse proxy) in front of the
# iPolloWork host on 127.0.0.1:8787, so the SPA and the API share an origin,
# which is what web deployments expect (`${origin}/opencode`).

# syntax=docker/dockerfile:1

############################
# Stage 1 — build from source
############################
FROM node:22-bookworm-slim AS build

# Pinned upstream commit: this deployment applies patches/ on top of it, so the
# base revision is fixed to keep the patch (and the resulting image) reproducible.
ARG IPOLLOWORK_REF=4483434be463de3c137889e80ce38c97512478b3

ENV DEBIAN_FRONTEND=noninteractive \
    ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
    COREPACK_ENABLE_STRICT=0 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    pnpm_config_verify_deps_before_run=false

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ca-certificates curl unzip python3 make g++ pkg-config \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g bun@1.3.10 \
 && corepack enable

WORKDIR /src
RUN git init -q . \
 && git remote add origin https://github.com/Devin-AXIS/iPolloWork.git \
 && git fetch --depth 1 -q origin "${IPOLLOWORK_REF}" \
 && git checkout -q FETCH_HEAD

# Local patches against the pinned revision (see patches/README.md).
COPY patches /tmp/patches
RUN for p in /tmp/patches/*.patch; do git apply -v "$p"; done

RUN pnpm install --frozen-lockfile

# The full web UI. Placeholders are rewritten with the real values by
# entrypoint.sh at container start (the public origin is not known at build time).
RUN pnpm --filter @ipollowork/types build \
 && VITE_IPOLLOWORK_DEPLOYMENT=web \
    VITE_IPOLLOWORK_URL="__IPOLLOWORK_ORIGIN__" \
    VITE_IPOLLOWORK_TOKEN="__IPOLLOWORK_TOKEN__" \
    pnpm --filter @ipollowork/app build

# The UI is ~28 MB of assets and the main bundle alone is ~10 MB. Compressing
# them at build time (nginx serves them with gzip_static) keeps the runtime off
# the compression path, which is much faster to deliver on a small container.
RUN cd apps/app/dist \
 && find . -type f -size +1k \
      \( -name '*.js' -o -name '*.mjs' -o -name '*.css' -o -name '*.html' \
         -o -name '*.json' -o -name '*.svg' -o -name '*.txt' -o -name '*.wasm' \) \
      -exec gzip -9 -k {} +

# The orchestrator is self-contained when compiled, so a single binary is enough.
# Build it before `pnpm deploy`, which rewrites the workspace's node_modules.
RUN pnpm --filter ipollowork-orchestrator build:bin

# The server must run on Node: the Bun-compiled binary cannot load sharp's
# native module, and the server imports sharp at startup.
RUN pnpm --filter ipollowork-server build \
 && pnpm --filter ipollowork-server deploy --prod --legacy /out/server

# Fail the build (instead of shipping a broken runtime) if sharp's native
# binary is not resolvable from the deployed server tree.
RUN cd /out/server \
 && node -e "import('sharp').then(() => console.log('sharp ok')).catch((error) => { console.error('sharp failed:', error.message); process.exit(1); })" \
 && test -f /out/server/dist/cli.js

############################
# Stage 2 — runtime
############################
FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      nginx ca-certificates git tar unzip curl tini \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/nginx/sites-enabled/default

# OpenCode engine CLI (the orchestrator manages it as a sidecar).
RUN npm install -g opencode-ai@1.18.34 || npm install -g opencode-ai

COPY --from=build /src/apps/orchestrator/dist/bin/ipollowork /opt/ipollowork/ipollowork
COPY --from=build /out/server /opt/ipollowork/server
COPY --from=build /src/apps/app/dist /usr/share/nginx/html

# The built server resolves two things from outside its own package:
#   ../../../constants.json          -> /opt/constants.json
#   ../../../examples/plugin-packages -> /opt/ipollowork/examples/plugin-packages
COPY --from=build /src/constants.json /opt/constants.json
COPY --from=build /src/examples/plugin-packages /opt/ipollowork/examples/plugin-packages

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY entrypoint.sh /opt/ipollowork/entrypoint.sh
RUN chmod +x /opt/ipollowork/entrypoint.sh /opt/ipollowork/ipollowork

ENV IPOLLOWORK_DATA_DIR=/data/ipollowork-orchestrator \
    IPOLLOWORK_SIDECAR_DIR=/data/sidecars \
    IPOLLOWORK_SIDECAR_SOURCE=external \
    IPOLLOWORK_SERVER_BIN=/opt/ipollowork/server/dist/cli.js \
    IPOLLOWORK_BUNDLED_TEMPLATES_DIR=/opt/ipollowork/server/dist/bundled-templates \
    IPOLLOWORK_WORKSPACE=/workspace \
    IPOLLOWORK_HTTP_PORT=8080 \
    IPOLLOWORK_PORT=8787

EXPOSE 8080
VOLUME ["/workspace", "/data"]

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/ipollowork/entrypoint.sh"]
