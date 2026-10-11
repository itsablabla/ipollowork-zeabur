# iPolloWork on Zeabur

Deploys [iPolloWork](https://github.com/Devin-AXIS/iPolloWork) to
[Zeabur](https://zeabur.com) as a **single container** that serves the full
iPolloWork web UI (the same React app the desktop client renders) together with
the headless iPolloWork host, on one public origin.

## Why one container / one origin

iPolloWork's web deployment mode (`VITE_IPOLLOWORK_DEPLOYMENT=web`) expects the
UI and the host API to share an origin: the client resolves the engine at
`${window.location.origin}/opencode` and the host REST surface on the same
origin. nginx serves the static SPA and reverse-proxies the host routes
(`/opencode`, `/workspaces`, `/workspace`, `/health`, `/files`, …) to the
iPolloWork host on `127.0.0.1:8787`.

## Layout

| File | Purpose |
| --- | --- |
| `Dockerfile` | Multi-stage build: compiles `@ipollowork/app` (web UI) plus the `ipollowork-server` and `ipollowork-orchestrator` binaries from source, then assembles the nginx runtime image. |
| `nginx.conf` | Static SPA + reverse proxy to the host (SSE/WebSocket safe). |
| `entrypoint.sh` | Patches the built bundle with the runtime public origin and client token, starts the host, then runs nginx. |

## Build notes

The published `packaging/docker/Dockerfile` in the upstream repo runs
`npm install -g ipollowork-orchestrator`, but `ipollowork-orchestrator` and
`ipollowork-server` are **not published to the public npm registry**, so this
Dockerfile builds both from the cloned source instead:

```
pnpm --filter @ipollowork/types build
VITE_IPOLLOWORK_DEPLOYMENT=web pnpm --filter @ipollowork/app build
pnpm --filter ipollowork-server build
pnpm --filter ipollowork-server deploy --prod --legacy /out/server
pnpm --filter ipollowork-orchestrator build:bin
```

Two details that matter:

- The server runs on **Node**, from the `pnpm deploy` output, because the
  Bun-compiled binary (`build:bin`) cannot resolve `sharp`'s native module and
  the server imports `sharp` at startup. The build asserts `sharp` resolves.
- The orchestrator is started with `--sidecar-source external
  --ipollowork-server-bin /opt/ipollowork/server/dist/cli.js`, otherwise it
  looks for a bundled/downloaded server binary and never starts one.

## Local patches

`IPOLLOWORK_REF` pins upstream to one commit and `patches/` is applied on top of
it, so the image is reproducible and every local change is reviewable.
`patches/README.md` documents each patch and when it can be dropped. The current
patch replaces the orchestrator's OpenCode readiness probe: the SDK call stalls
inside this container, so `ipollowork serve` never starts the iPolloWork server
and the deployment answers 502 with only nginx and the SPA up.

## Required service configuration (Zeabur)

- Port: `8080` (HTTP, public domain)
- Volumes: `/data` (tokens, sidecars, engine caches) and `/workspace` (project files)
- Variables:
  - `IPOLLOWORK_TOKEN` — client bearer token for the UI/API
  - `IPOLLOWORK_HOST_TOKEN` — host/owner token (approvals)
  - `IPOLLOWORK_PUBLIC_ORIGIN` — `https://<service-domain>` (falls back to `ZEABUR_WEB_URL`)
  - `IPOLLOWORK_APPROVAL_MODE` — `manual` (default) or `auto`
  - `IPOLLOWORK_EMBED_TOKEN` — `1` (default) bakes the client token into the
    served bundle so the UI connects immediately; set `0` to require entering a
    token in the UI instead

## Security

With `IPOLLOWORK_EMBED_TOKEN=1` anyone who can load the site gets the client
token and therefore agent execution on this instance. Keep the URL private,
keep approval mode `manual`, and rotate `IPOLLOWORK_TOKEN` (and the tokens
stored under `/data`) if the link leaks.
