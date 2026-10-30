// The web app's "Update available" bar (MF-127), in headless Chrome against the local stack:
//   node server/test/e2e-web-update.mjs http://localhost:8788 [path to Chrome]
// The local stack needs DEV_LOGIN in .dev.vars, so the browser is signed in on localhost. A stand-in
// WebSocket in the page drops the feed on cue and, once asked, reports a bumped serverVersion in the
// next snapshot, the way a deploy restarts the hub and reconnects with the new version. Checks: a plain
// reconnect with the same version leaves the bar hidden; one with a new version shows it, without a
// reload; Refresh reloads the page, and the bar is gone on the fresh load.

import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [base = "http://localhost:8788", chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"] = process.argv.slice(2);
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };
const wait = async (what, test, ms = 15000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = await test();
    if (hit) return hit;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 100));
  }
};

// Headless Chrome with a throwaway profile, driven over the DevTools protocol.
const profile = mkdtempSync(join(tmpdir(), "maple-web-update-"));
const chrome = spawn(chromePath, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run", "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
const devtools = await new Promise((resolve, reject) => {
  let err = "";
  chrome.stderr.on("data", (d) => { err += d; const m = /DevTools listening on (ws:\/\/\S+)/.exec(err); if (m) resolve(m[1]); });
  chrome.on("exit", () => reject(new Error(`Chrome exited: ${err}`)));
});
const debug = devtools.replace(/^ws:\/\/([^/]+).*/, "http://$1");
const target = await (await fetch(`${debug}/json/new?about:blank`, { method: "PUT" })).json();
const page = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => (page.onopen = r));
let nextId = 1;
const pending = new Map();
const loads = [];
page.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  if (m.method === "Page.loadEventFired") loads.push(Date.now());
};
const cdp = (method, params = {}) => new Promise((resolve, reject) => {
  const id = nextId++;
  pending.set(id, (m) => (m.error ? reject(new Error(`${method}: ${m.error.message}`)) : resolve(m.result)));
  page.send(JSON.stringify({ id, method, params }));
});
const js = async (expression) => (await cdp("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result.value;

// The stand-in WebSocket: every socket the app opens, and window.__bump to rewrite the next snapshot's version.
await cdp("Page.enable");
await cdp("Page.addScriptToEvaluateOnNewDocument", { source: `(() => {
  const Native = WebSocket;
  window.__sockets = [];
  window.WebSocket = class extends Native {
    constructor(...args) { super(...args); window.__sockets.push(this); }
    set onmessage(fn) {
      super.onmessage = (e) => {
        const m = JSON.parse(e.data);
        if (m.type === "snapshot" && window.__bump) { m.serverVersion = window.__bump; return fn(new MessageEvent("message", { data: JSON.stringify(m) })); }
        fn(e);
      };
    }
  };
})();` });

const live = () => js(`document.getElementById("status")?.textContent === "Live"`);
const barShown = () => js(`!document.getElementById("update").hidden`);
const reconnect = async () => {
  const before = await js("window.__sockets.length");
  await js("window.__sockets.at(-1).close()");
  await wait("the socket to drop", async () => !(await live()));
  await wait("the reconnect", async () => (await js("window.__sockets.length")) > before && (await live()));
};

try {
  await cdp("Page.navigate", { url: `${base}/app` });
  await wait("the app to go live", live);
  const loaded = await js(`fetch("/healthz").then((r) => r.json()).then((j) => j.version).catch(() => null)`);
  check(!(await barShown()), `no bar on the first load (maple-server ${loaded ?? "?"})`);

  // A network blip: the same version comes back.
  await reconnect();
  check(!(await barShown()), "a reconnect with the same serverVersion leaves the bar hidden");

  // A deploy: the hub restarts and the snapshot after the reconnect reports a new version.
  const loadsBefore = loads.length;
  await js(`window.__bump = "99.0.0"`);
  await reconnect();
  await wait("the update bar", barShown, 5000).catch(() => false);
  check(await barShown(), "a reconnect with a new serverVersion shows the update bar");
  check(loads.length === loadsBefore, "the bar came up without reloading the page");
  check(/Maple Factory was updated/.test(await js(`document.getElementById("update").textContent`)), "the bar says Maple Factory was updated");

  // Refresh: a fresh load of the page, where the version it loads with is the current one.
  await js(`document.getElementById("update-refresh").click()`);
  await wait("the page to reload", () => loads.length > loadsBefore);
  await wait("the app to go live again", live);
  check((await js("window.__bump")) === undefined, "Refresh reloaded the page");
  check(!(await barShown()), "the bar is gone after the reload");
} catch (e) {
  check(false, e.message);
} finally {
  page.close();
  chrome.kill();
  await new Promise((r) => (chrome.exitCode === null ? chrome.once("exit", r) : r()));
  rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);
