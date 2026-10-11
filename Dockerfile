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

ARG IPOLLOWORK_REF=main

ENV DEBIAN_FRONTEND=noninteractive \
    ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
    COREPACK_ENABLE_STRICT=0 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ca-certificates curl unzip python3 make g++ pkg-config \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g bun@1.3.10 \
 && corepack enable

WORKDIR /src
RUN git clone --depth 1 --branch "${IPOLLOWORK_REF}" \
      https://github.com/Devin-AXIS/iPolloWork.git .

RUN pnpm install --frozen-lockfile

# The full web UI. Placeholders are rewritten with the real values by
# entrypoint.sh at container start (the public origin is not known at build time).
RUN pnpm --filter @ipollowork/types build \
 && VITE_IPOLLOWORK_DEPLOYMENT=web \
    VITE_IPOLLOWORK_URL="__IPOLLOWORK_ORIGIN__" \
    VITE_IPOLLOWORK_TOKEN="__IPOLLOWORK_TOKEN__" \
    pnpm --filter @ipollowork/app build

# The server must run on Node: the Bun-compiled binary cannot load sharp's
# native module, and the server imports sharp at startup.
RUN pnpm --filter ipollowork-server build \
 && pnpm --filter ipollowork-server deploy --prod --legacy /out/server

# Fail the build (instead of shipping a broken runtime) if sharp's native
# binary is not resolvable from the deployed server tree.
RUN cd /out/server \
 && node -e "import('sharp').then(() => console.log('sharp ok')).catch((error) => { console.error('sharp failed:', error.message); process.exit(1); })" \
 && test -f /out/server/dist/cli.js

# The orchestrator is self-contained when compiled, so a single binary is enough.
RUN pnpm --filter ipollowork-orchestrator build:bin

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
