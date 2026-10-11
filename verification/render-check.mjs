// Renders the deployed SPA in a local headless Chrome (via CDP) and reports
// whether the app actually boots: console errors, failed requests, and the
// rendered text once the startup splash goes away.
import { setTimeout as sleep } from "node:timers/promises";

const URL_TO_OPEN = process.argv[2];
const DEBUG_PORT = process.argv[3] ?? "9223";

const listTargets = async () => {
  for (let i = 0; i < 40; i += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/list`);
      const targets = await response.json();
      const page = targets.find((t) => t.type === "page");
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch {}
    await sleep(500);
  }
  throw new Error("no debuggable page target");
};

const wsUrl = await listTargets();
const socket = new WebSocket(wsUrl);
await new Promise((resolve, reject) => {
  socket.onopen = resolve;
  socket.onerror = (event) => reject(new Error(`ws error: ${event?.message ?? "unknown"}`));
});

let nextId = 1;
const pending = new Map();
const consoleMessages = [];
const failedRequests = [];
const responses = [];

socket.onmessage = (event) => {
  const message = JSON.parse(event.data);
  if (message.id && pending.has(message.id)) {
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(JSON.stringify(message.error)));
    else resolve(message.result);
    return;
  }
  if (message.method === "Runtime.consoleAPICalled") {
    const text = (message.params.args ?? [])
      .map((a) => a.value ?? a.description ?? a.type)
      .join(" ");
    consoleMessages.push(`${message.params.type}: ${text}`.slice(0, 400));
  }
  if (message.method === "Runtime.exceptionThrown") {
    consoleMessages.push(`exception: ${message.params.exceptionDetails?.exception?.description ?? message.params.exceptionDetails?.text}`.slice(0, 400));
  }
  if (message.method === "Network.loadingFailed") {
    failedRequests.push(`${message.params.type} ${message.params.errorText}`);
  }
  if (message.method === "Network.responseReceived") {
    const { url, status } = message.params.response;
    if (status >= 400) responses.push(`${status} ${url.slice(0, 140)}`);
  }
};

const send = (method, params = {}) =>
  new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });

await send("Runtime.enable");
await send("Network.enable");
await send("Page.enable");
await send("Page.navigate", { url: URL_TO_OPEN });

const readState = async () => {
  const result = await send("Runtime.evaluate", {
    expression: `(() => {
      const root = document.getElementById('root');
      const splash = document.getElementById('ipollowork-startup-splash');
      return JSON.stringify({
        rootChildren: root ? root.childElementCount : -1,
        splashPresent: Boolean(splash),
        text: (document.body.innerText || '').replace(/\\s+/g, ' ').slice(0, 700),
      });
    })()`,
    returnByValue: true,
  });
  return JSON.parse(result.result.value);
};

let state = await readState();
for (let attempt = 0; attempt < 24; attempt += 1) {
  if (state.rootChildren > 0 && !state.splashPresent) break;
  await sleep(5000);
  state = await readState();
  console.log(`[t=${(attempt + 1) * 5}s] root=${state.rootChildren} splash=${state.splashPresent}`);
}

console.log("\n=== final state ===");
console.log(JSON.stringify(state, null, 2));
console.log("\n=== console messages ===");
console.log(consoleMessages.slice(0, 40).join("\n") || "(none)");
console.log("\n=== responses >= 400 ===");
console.log(responses.slice(0, 30).join("\n") || "(none)");
console.log("\n=== failed requests ===");
console.log(failedRequests.slice(0, 20).join("\n") || "(none)");
socket.close();
