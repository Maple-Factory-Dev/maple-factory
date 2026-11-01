// Signing out of the web app (MF-246), in headless Chrome against its own `wrangler dev`:
//   node server/test/e2e-web-signout.mjs [path to Chrome]
// DEV_LOGIN would sign the browser straight back in, so this starts a local server without it, with a
// SESSION_SECRET of its own, a throwaway database holding one member, and gives Chrome a session cookie
// signed the way /auth/callback signs one. Checks: the app goes live as that member and shows their
// account button; the menu has their name, @login and Sign out; Sign out POSTs /auth/logout, the session
// cookie is gone, /api/me answers 401, the sign-in screen says "You've signed out", the feed doesn't
// reconnect, and a reload stays signed out. Set FRAMES=<dir> to keep a JPEG per screencast frame.

import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const [chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"] = process.argv.slice(2);
const server = join(dirname(fileURLToPath(import.meta.url)), "..");
const wrangler = join(server, "..", "node_modules", ".bin", "wrangler");
const port = 8800 + Math.floor(Math.random() * 100);
const base = `http://localhost:${port}`;
const secret = `signout-test-${Date.now()}`;
const login = "octo-signout";
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };
const wait = async (what, test, ms = 20000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = await test();
    if (hit) return hit;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 100));
  }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A session cookie, as src/util.ts sign() makes one.
const b64url = (b) => Buffer.from(b).toString("base64url");
async function sign(payload) {
  const body = b64url(JSON.stringify(payload));
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return `${body}.${b64url(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)))}`;
}

// The server: its own database with one member, checked just now so nobody asks GitHub.
const persist = mkdtempSync(join(tmpdir(), "maple-signout-db-"));
const d1 = (...args) => execFileSync(wrangler, ["d1", ...args, "maple", "--local", "--persist-to", persist], { cwd: server, stdio: "pipe", env: { ...process.env, CI: "1" } });
d1("migrations", "apply");
const now = Date.now();
d1("execute", "--command", `INSERT INTO members (login, github_id, name, avatar_url, role, teams, created_at, last_seen, checked_at) VALUES ('${login}', 1, 'Octo Signout', NULL, 'member', '[]', ${now}, ${now}, ${now})`);
const dev = spawn(wrangler, ["dev", "--port", String(port), "--persist-to", persist, "--var", `SESSION_SECRET:${secret}`, "--var", "GITHUB_ORG:acme", "--var", "DEV_LOGIN:"], { cwd: server, stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, CI: "1" } });
let devLog = "";
dev.stdout.on("data", (d) => (devLog += d));
dev.stderr.on("data", (d) => (devLog += d));

let chrome, profile, page;
try {
  const health = await wait("wrangler dev", () => fetch(`${base}/healthz`).then((r) => r.json()).catch(() => null), 60000);
  check(health.signIn !== "dev", `the server has no DEV_LOGIN (sign-in: ${health.signIn})`);

  // Headless Chrome with a throwaway profile, driven over the DevTools protocol.
  profile = mkdtempSync(join(tmpdir(), "maple-web-signout-"));
  chrome = spawn(chromePath, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run", "--window-size=1100,720", "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
  const devtools = await new Promise((resolve, reject) => {
    let err = "";
    chrome.stderr.on("data", (d) => { err += d; const m = /DevTools listening on (ws:\/\/\S+)/.exec(err); if (m) resolve(m[1]); });
    chrome.on("exit", () => reject(new Error(`Chrome exited: ${err}`)));
  });
  const debug = devtools.replace(/^ws:\/\/([^/]+).*/, "http://$1");
  const target = await (await fetch(`${debug}/json/new?about:blank`, { method: "PUT" })).json();
  page = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r) => (page.onopen = r));
  let nextId = 1;
  const pending = new Map();
  const requests = [];
  let frame = 0;
  page.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
    if (m.method === "Network.requestWillBeSent") requests.push({ method: m.params.request.method, url: m.params.request.url });
    if (m.method === "Page.screencastFrame") {
      writeFileSync(join(process.env.FRAMES, `${String(frame++).padStart(5, "0")}-${Math.round(m.params.metadata.timestamp * 1000)}.jpg`), Buffer.from(m.params.data, "base64"));
      page.send(JSON.stringify({ id: nextId++, method: "Page.screencastFrameAck", params: { sessionId: m.params.sessionId } }));
    }
  };
  const cdp = (method, params = {}) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, (m) => (m.error ? reject(new Error(`${method}: ${m.error.message}`)) : resolve(m.result)));
    page.send(JSON.stringify({ id, method, params }));
  });
  const js = async (expression) => (await cdp("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result.value;
  const cookies = async () => (await cdp("Network.getCookies", { urls: [base] })).cookies.map((c) => c.name);

  await cdp("Page.enable");
  await cdp("Network.enable");
  // Every socket the app opens, to tell a reconnect.
  await cdp("Page.addScriptToEvaluateOnNewDocument", { source: `(() => {
    const Native = WebSocket;
    window.__sockets = [];
    window.WebSocket = class extends Native { constructor(...args) { super(...args); window.__sockets.push(this); } };
  })();` });
  if (process.env.FRAMES) {
    mkdirSync(process.env.FRAMES, { recursive: true });
    await cdp("Page.startScreencast", { format: "jpeg", quality: 85, maxWidth: 1100, maxHeight: 720, everyNthFrame: 1 });
  }
  const session = await sign({ login, iat: Date.now(), exp: Math.floor(Date.now() / 1000) + 3600 });
  await cdp("Network.setCookie", { name: "maple_session", value: session, url: base, httpOnly: true, sameSite: "Lax" });

  // Signed in with the real cookie.
  await cdp("Page.navigate", { url: `${base}/app/#/tasks` });
  await wait("the app to go live", () => js(`document.getElementById("status")?.textContent === "Live"`));
  check((await js(`fetch("/api/me").then((r) => r.status)`)) === 200, "/api/me answers 200 with the session cookie");
  check(await js(`!document.getElementById("account").hidden`), "the account button shows once signed in");
  check((await js(`document.getElementById("account-avatar").textContent`)) === "O", "with the member's initial (no avatar URL)");
  await sleep(600);

  // The menu.
  await js(`document.getElementById("account-btn").click()`);
  check(await js(`!document.getElementById("account-menu").hidden && document.getElementById("account-btn").getAttribute("aria-expanded") === "true"`), "clicking it opens the menu");
  check((await js(`document.getElementById("account-name").textContent`)) === "Octo Signout", "the menu has the member's name");
  check((await js(`document.getElementById("account-login").textContent`)) === `@${login}`, "and their @login");
  await cdp("Input.dispatchKeyEvent", { type: "keyDown", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 });
  check(await js(`document.getElementById("account-menu").hidden`), "Escape closes it");
  await js(`document.getElementById("account-btn").click()`);
  await js(`document.querySelector("main").dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }))`);
  check(await js(`document.getElementById("account-menu").hidden`), "a click outside closes it");
  await js(`document.getElementById("account-btn").click()`);
  await sleep(900);

  // Sign out.
  const socketsBefore = await js("window.__sockets.length");
  await js(`document.getElementById("account-signout").click()`);
  await wait("the sign-in screen", () => js(`!!document.querySelector(".signin")`));
  check(requests.some((r) => r.method === "POST" && r.url === `${base}/auth/logout`), "Sign out POSTs /auth/logout");
  check(!(await cookies()).includes("maple_session"), "the session cookie is cleared");
  check((await js(`fetch("/api/me").then((r) => r.status)`)) === 401, "/api/me answers 401 afterwards");
  check(/You've signed out of acme\./.test(await js(`document.querySelector(".signin").textContent`)), `the sign-in screen says "You've signed out of acme."`);
  check(await js(`document.getElementById("account").hidden`), "the account button is hidden");
  const next = await js(`new URL(document.querySelector(".signin a").href).searchParams.get("next")`);
  check(next === "/app/" && (await js("location.hash")) === "", `Sign in with GitHub comes back to the inbox, not the old page (next=${next})`);
  await sleep(3500); // the app retries after 1s, then 2s
  check((await js("window.__sockets.length")) === socketsBefore, `the feed doesn't reconnect (${await js("window.__sockets.length")} socket(s) opened, ${socketsBefore} before)`);
  const ready = await js("window.__sockets.at(-1).readyState");
  check(ready >= 2, `and its socket is closed (readyState ${ready})`);

  // A reload stays signed out.
  await cdp("Page.reload");
  await wait("the sign-in screen after a reload", () => js(`!!document.querySelector(".signin")`));
  check((await js("location.pathname")) === "/app/" && (await js(`document.getElementById("status").textContent`)) !== "Live", "a reload stays signed out, on the app");
  check((await js(`document.getElementById("status").textContent`)) === "Signed out", "the header says Signed out, not Reconnecting…");
  await sleep(800);
  if (process.env.FRAMES) await cdp("Page.stopScreencast");
} catch (e) {
  check(false, e.message);
  console.log(devLog.slice(-2000));
} finally {
  page?.close();
  chrome?.kill();
  if (chrome) await new Promise((r) => (chrome.exitCode === null ? chrome.once("exit", r) : r()));
  dev.kill();
  await new Promise((r) => (dev.exitCode === null ? dev.once("exit", r) : r()));
  for (const dir of [profile, persist]) if (dir) rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);
