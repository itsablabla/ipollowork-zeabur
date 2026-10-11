# Local patches

Applied to the pinned upstream revision (`IPOLLOWORK_REF` in the Dockerfile)
during the image build.

## 0001-opencode-health-probe.patch

`apps/orchestrator/src/cli.ts`

The orchestrator waits for OpenCode readiness through the `@opencode-ai/sdk`
client, which scopes every request with `?directory=<workspace>`. Inside this
container that request never returns, so `ipollowork serve` stalls at
`[opencode] Waiting for health` and never starts the iPolloWork server (the
deployment answers 502 with only nginx and the SPA running).

Reproduced in the container:

- `curl -u "$USER:$PASS" http://127.0.0.1:4096/global/health` returns 200 in ~20ms.
- `ipollowork status --opencode-url http://127.0.0.1:4096` never completes.
- The same SDK call succeeds when a Node proxy sits in front of OpenCode.
- `ipollowork serve` never logs `[opencode] Healthy`.

The patch:

1. Adds an optional `probe` argument to `waitForOpencodeHealthy`. When it is
   passed, the readiness check probes `/global/health` with a plain `fetch`
   (Basic auth, no `directory` parameter) instead of the SDK call. Every call
   site that starts or verifies services passes its base URL and managed
   credentials.
2. Bounds each attempt (`AbortSignal.timeout`) and, for services the
   orchestrator starts itself, continues after `DEGRADED_OPENCODE_PROBE_MS`
   with `degraded: true` and a warning instead of hanging. OpenCode traffic in
   the running app goes through the iPolloWork server on Node, which talks to
   OpenCode without trouble, so a failed direct probe does not mean the engine
   is unusable. `ipollowork status` stays strict so it still reports honestly.

Delete this patch once upstream's health check works against OpenCode 1.18.34 in
a container, and re-pin `IPOLLOWORK_REF`.
