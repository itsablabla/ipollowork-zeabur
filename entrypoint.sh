#!/usr/bin/env bash
# Container entrypoint: patch the built web bundle with runtime values,
# start the iPolloWork headless host, then run nginx in the foreground.
set -euo pipefail

WEB_ROOT="${IPOLLOWORK_WEB_ROOT:-/usr/share/nginx/html}"
HOST_PORT="${IPOLLOWORK_PORT:-8787}"
HTTP_PORT="${IPOLLOWORK_HTTP_PORT:-8080}"

log() { printf '[ipollowork] %s\n' "$*"; }

replace_placeholder() {
  local placeholder="$1" value="$2" file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    sed -i "s|${placeholder}|${value}|g" "$file"
  done < <(grep -rl -- "$placeholder" "$WEB_ROOT" 2>/dev/null || true)
}

# ---------------------------------------------------------------- runtime config
# The SPA is built with `VITE_IPOLLOWORK_DEPLOYMENT=web`; it expects to talk to
# its own origin. The public origin is only known once Zeabur assigns a domain,
# so the build bakes placeholders and we substitute them here.
ORIGIN="${IPOLLOWORK_PUBLIC_ORIGIN:-${ZEABUR_WEB_URL:-${PUBLIC_ORIGIN:-}}}"
ORIGIN="${ORIGIN%/}"

if [ -n "$ORIGIN" ]; then
  log "web bundle origin -> ${ORIGIN}"
else
  log "no public origin provided; the UI will use same-origin defaults"
fi
replace_placeholder "__IPOLLOWORK_ORIGIN__" "$ORIGIN"

if [ "${IPOLLOWORK_EMBED_TOKEN:-1}" = "1" ] && [ -n "${IPOLLOWORK_TOKEN:-}" ]; then
  log "embedding the client token in the web bundle (IPOLLOWORK_EMBED_TOKEN=0 disables)"
  replace_placeholder "__IPOLLOWORK_TOKEN__" "${IPOLLOWORK_TOKEN}"
else
  log "not embedding a client token; connect with a token in the UI"
  replace_placeholder "__IPOLLOWORK_TOKEN__" ""
fi

# ------------------------------------------------------------------- state dirs
mkdir -p \
  "${IPOLLOWORK_DATA_DIR:-/data/ipollowork-orchestrator}" \
  "${IPOLLOWORK_SIDECAR_DIR:-/data/sidecars}" \
  "${IPOLLOWORK_WORKSPACE:-/workspace}"

export IPOLLOWORK_BUNDLED_TEMPLATES_DIR="${IPOLLOWORK_BUNDLED_TEMPLATES_DIR:-/opt/ipollowork/bundled-templates}"

# ------------------------------------------------------------------ host process
OPENCODE_ARGS=()
if [ -x /usr/local/bin/opencode ]; then
  OPENCODE_ARGS+=(--opencode-bin /usr/local/bin/opencode)
  log "using opencode at /usr/local/bin/opencode"
fi

log "starting iPolloWork host on 127.0.0.1:${HOST_PORT}"
/opt/ipollowork/ipollowork serve \
  --workspace "${IPOLLOWORK_WORKSPACE:-/workspace}" \
  --remote-access \
  --ipollowork-port "${HOST_PORT}" \
  --opencode-host 127.0.0.1 \
  --opencode-port 4096 \
  --connect-host 127.0.0.1 \
  --cors '*' \
  --approval "${IPOLLOWORK_APPROVAL_MODE:-manual}" \
  --allow-external \
  --ipollowork-server-bin /opt/ipollowork/ipollowork-server \
  "${OPENCODE_ARGS[@]}" &
HOST_PID=$!

cleanup() {
  if kill -0 "$HOST_PID" 2>/dev/null; then
    kill "$HOST_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:${HOST_PORT}/health" >/dev/null 2>&1; then
    log "iPolloWork host is healthy"
    break
  fi
  if ! kill -0 "$HOST_PID" 2>/dev/null; then
    log "iPolloWork host exited during startup"
    wait "$HOST_PID" || true
    exit 1
  fi
  sleep 1
done

log "starting nginx on ${HTTP_PORT}"
nginx -g 'daemon off;'
