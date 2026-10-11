// Screenshots the deployed UI through CDP once the app shell has mounted.
import { writeFile } from "node:fs/promises";
import { setTimeout as sleep } from "node:timers/promises";

const url = process.argv[2];
const port = process.argv[3] ?? "9224";
const outFile = process.argv[4] ?? "ipollowork-web-ui.png";

const findTarget = async () => {
  for (let i = 0; i < 40; i += 1) {
    try {
      const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      const page = targets.find((t) => t.type === "page");
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch {}
    await sleep(500);
  }
  throw new Error("no debuggable page target");
};

const socket = new WebSocket(await findTarget());
await new Promise((resolve, reject) => {
  socket.onopen = resolve;
  socket.onerror = () => reject(new Error("ws error"));
});

let nextId = 1;
const pending = new Map();
socket.onmessage = (event) => {
  const message = JSON.parse(event.data);
  const entry = pending.get(message.id);
  if (!entry) return;
  pending.delete(message.id);
  if (message.error) entry.reject(new Error(JSON.stringify(message.error)));
  else entry.resolve(message.result);
};

const send = (method, params = {}) =>
  new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });

await send("Page.enable");
await send("Page.navigate", { url });

const mounted = async () => {
  const result = await send("Runtime.evaluate", {
    expression: `(() => {
      const root = document.getElementById('root');
      return (root ? root.childElementCount : 0) > 0 && !document.getElementById('ipollowork-startup-splash');
    })()`,
    returnByValue: true,
  });
  return result.result.value === true;
};

for (let attempt = 0; attempt < 30; attempt += 1) {
  if (await mounted()) break;
  await sleep(2000);
}
await sleep(6000);

const shot = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
await writeFile(outFile, Buffer.from(shot.data, "base64"));

const text = await send("Runtime.evaluate", {
  expression: "document.body.innerText.replace(/\\s+/g,' ').slice(0,400)",
  returnByValue: true,
});
console.log("mounted:", await mounted());
console.log("text:", text.result.value);
console.log("wrote:", outFile);
socket.close();
