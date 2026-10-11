# Deployment verification

Target: `https://ipollowork-garza.zeabur.app` (Zeabur, project `6acb6f34faa6e043a4b664f8`)

## HTTP surface (authenticated with `IPOLLOWORK_TOKEN`)

| Route | Result |
| --- | --- |
| `/healthz` | 200 `ok` (nginx) |
| `/health` | 200 `{"ok":true,"version":"0.50.13","opencodeVersion":"1.18.34"}` |
| `/whoami` | 200, actor scope `collaborator` |
| `/workspaces` | 200, one local workspace at `/workspace` |
| `/opencode/global/health` | 200 `{"healthy":true,"version":"1.18.34"}` |
| `/opencode/path`, `/opencode/app`, `/opencode/config` | 200 |

## Engine round trip

Created, listed, and deleted an OpenCode session through `/opencode/session?directory=/workspace`
over the public origin (200 on all three calls). Test sessions were removed afterwards.

## Browser render (headless Chrome over CDP)

`render-check.mjs` reports the SPA mounts and the startup splash is removed:

```
rootChildren: 2, splashPresent: false
text: "workspace Conversation Overview Tasks Turn ideas into outcomes Work Code Create Video
Automate the computer Document processing Spreadsheet processing Deep research Operate the
browser OpenCode Choose a direction, or describe the work in your own words. Select model
Agent defaults Execute ..."
```

`ipollowork-web-ui.png` is the screenshot from that run (`capture-screenshot.mjs`).

## Asset delivery

`/assets/app-*.js` is 10.16 MB uncompressed, 2.24 MB gzipped. Pre-compressed at build
time and served with `gzip_static`: 1.7 s to a browser, down from ~140 s when nginx
compressed it per request (chunked responses are delivered slowly through the edge).

## Known limitations

- `POST /workspaces/<id>/activate` returns 401 for a remote browser client. Upstream
  sends the host token only when the server URL is loopback, so a shared deployment stays
  collaborator-scoped by design. Sessions, files, and the engine still work.
- No model provider is configured, so the composer shows "Reading the model catalog...".
  Add provider credentials in the UI before running an agent.
