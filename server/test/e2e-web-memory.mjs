#!/usr/bin/env node
// MF-394, the web companion's Memory page in a real browser (Playwright), against a stand-in feed:
//   node server/test/e2e-web-memory.mjs [--headed]
// Serves server/web as the worker would and answers /client/connect itself (page.routeWebSocket) with a
// snapshot holding a goal, a task (MF-391) and four memories: different kinds, two repos, one learned on
// MF-391, one active and made 120 days ago (Stale), one proposed. The stand-in answers the page's
// memory.edit and memory.status the way the org hub does (server/src/org-hub.ts, covered by its own tests):
// with memory.updated. Checks: #/memory filters by kind and by repo; Edit saves new text (memory.edit) and
// the row shows it; Archive (memory.status) moves a memory under Archived; the provenance's task link opens
// #/t/MF-391, whose timeline says "Remembered 1 thing" and links back to #/memory?task=MF-391; Settings ›
// Repositories links each repo's memories. Screenshots go to ~/.cache/maple-proof/agent/mf-394/.
// Playwright: `playwright` if it resolves, else the newest in ~/.npm/_npx (npx playwright …); browser:
// the installed Google Chrome (PLAYWRIGHT_CHANNEL to change it).
import { createServer } from "node:http";
import { readFile, mkdir, readdir, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join, extname, normalize } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const web = fileURLToPath(new URL("../web/", import.meta.url));
const proof = join(homedir(), ".cache/maple-proof/agent/mf-394");
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };

async function loadPlaywright() {
  try { return await import("playwright"); } catch {}
  const npx = join(homedir(), ".npm/_npx");
  const found = [];
  for (const d of existsSync(npx) ? await readdir(npx) : []) {
    const entry = join(npx, d, "node_modules/playwright/index.mjs");
    if (existsSync(entry)) found.push({ entry, at: (await stat(entry)).mtimeMs });
  }
  if (!found.length) throw new Error("Playwright isn't installed: npx playwright --version, or npm i -D playwright");
  return import(pathToFileURL(found.sort((a, b) => b.at - a.at)[0].entry).href);
}

// ---- the web app's files, served like the worker's assets: / is the app ----
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".woff2": "font/woff2" };
const files = createServer(async (req, res) => {
  const path = new URL(req.url, "http://x").pathname;
  if (path.startsWith("/api/") || path.startsWith("/auth/")) { res.writeHead(path === "/api/me" ? 200 : 404, { "content-type": "application/json" }); return res.end("{}"); }
  const file = normalize(join(web, path === "/" ? "app/index.html" : path));
  if (!file.startsWith(web)) { res.writeHead(403); return res.end(); }
  try {
    const body = await readFile(file);
    res.writeHead(200, { "content-type": TYPES[extname(file)] ?? "application/octet-stream" });
    res.end(body);
  } catch { res.writeHead(404); res.end(); }
});
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${files.address().port}`;

// ---- the stand-in feed ----
const now = Date.now();
const DAY = 86_400_000;
const me = { login: "afomera", name: "Andrea", role: "admin", avatar: null };
const goal = { id: "g-mf", name: "Maple Factory", prefix: "MF", color: "#d24e26", summary: "", lead: "afomera", repos: ["acme/web", "acme/api"], repo: "acme/web" };
const task = {
  id: "MF-391", goal: goal.id, title: "Shared memory for agents", state: "building", owner: "afomera", brief: "Let agents remember things between tasks.",
  createdAt: now - 3 * DAY, updatedAt: now - DAY, plan: [{ text: "Add remember/recall/forget", file: "server/src/memories.ts" }], planVersion: 1,
  doneWhen: [], approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, requested: [], comments: [], changes: [],
  events: [{ at: now - 3 * DAY, who: "afomera", text: "created the task" }, { at: now - 2 * DAY, who: "planner", text: "submitted a plan" }],
  stages: [], mockups: [], diagrams: [], artifacts: [], tickets: [], shareable: false, agent: "claude", after: [], followUps: [], repo: "acme/web",
};
const memory = (id, o) => ({ id, scope: { kind: "repo", key: "acme/web" }, kind: "fact", text: "", tags: [], status: "active", source: { by: "afomera" }, createdAt: now - 10 * DAY, updatedAt: now - 10 * DAY, lastUsedAt: null, uses: 0, ...o });
const memories = [
  memory("00000000-0000-4000-8000-000000000001", { kind: "gotcha", text: "npm test needs Docker running for the D1 shim.", tags: ["tests", "docker"],
    source: { by: "afomera", task: "MF-391", role: "builder", agent: "MF-391 builder", machine: "mbp-14" }, createdAt: now - 2 * DAY, updatedAt: now - 2 * DAY, lastUsedAt: now - 3 * DAY, uses: 12 }),
  memory("00000000-0000-4000-8000-000000000002", { kind: "convention", text: "API handlers return { error } with a 4xx, never throw.", tags: ["api"], scope: { kind: "repo", key: "acme/api" }, updatedAt: now - 5 * DAY, uses: 3, lastUsedAt: now - 5 * DAY }),
  memory("00000000-0000-4000-8000-000000000003", { kind: "fact", text: "The marketing site deploys from the gh-pages branch.", tags: ["deploy"], createdAt: now - 120 * DAY, updatedAt: now - 120 * DAY }),
  memory("00000000-0000-4000-8000-000000000004", { kind: "preference", text: "Andrea likes small PRs, one concern each.", scope: { kind: "org", key: null }, status: "proposed", updatedAt: now - DAY,
    source: { by: "afomera", agent: "MF-388 reviewer", machine: "mbp-14" } }),
];
const snapshot = {
  type: "snapshot", me, org: "acme", name: "Acme", members: [me], goals: [goal], tasks: [task], tallies: [], notes: [], machines: [], docs: [], decisions: [],
  repos: [{ name: "acme/api", source: "github", isPrivate: true, defaultBranch: "main" }, { name: "acme/web", source: "github", isPrivate: true, defaultBranch: "main" }],
  repoOwners: [], secrets: [], policy: null, prompts: null, memories,
};
const sent = [];

const { chromium } = await loadPlaywright();
const browser = await chromium.launch({ channel: process.env.PLAYWRIGHT_CHANNEL ?? "chrome", headless: !process.argv.includes("--headed") });
const page = await browser.newPage({ viewport: { width: 1100, height: 900 } });
const pageErrors = [];
page.on("pageerror", (e) => pageErrors.push(e.message));
await page.routeWebSocket(/\/client\/connect/, (ws) => {
  ws.onMessage((raw) => {
    const m = JSON.parse(String(raw));
    sent.push(m);
    if (m.type === "subscribe") return ws.send(JSON.stringify(snapshot));
    const mem = memories.find((x) => x.id === m.id);
    if (!mem) return;
    if (m.type === "memory.edit") Object.assign(mem, Object.fromEntries(["text", "kind", "tags", "scope"].filter((k) => m[k] != null).map((k) => [k, m[k]])));
    else if (m.type === "memory.status") mem.status = m.status;
    else return;
    mem.updatedAt = Date.now();
    ws.send(JSON.stringify({ type: "memory.updated", memory: mem }));
  });
});

const rows = () => page.getByTestId("memory-row");
const texts = async () => (await page.getByTestId("memory-text").allTextContents()).sort();
/** Waits (up to 5s) for `test` to hold: a hash change renders on its hashchange, a moment after. */
const until = async (test) => { for (const end = Date.now() + 5000; Date.now() < end; await page.waitForTimeout(50)) if (await test()) return true; return false; };
const shows = (want) => until(async () => JSON.stringify(await texts()) === JSON.stringify(want));

try {
  await page.goto(`${base}/#/memory`);
  await page.getByTestId("memory-page").waitFor();
  check(await page.locator('[data-nav="memory"]').isVisible(), "the nav has Memory");
  check(await rows().count() === 3, `Active lists the three active memories (${await rows().count()})`);
  const staleRow = rows().filter({ hasText: "gh-pages" });
  check(await staleRow.getByTestId("memory-stale").count() === 1, "the one made 120 days ago and never used is Stale");
  check(await rows().filter({ hasText: "Docker" }).getByTestId("memory-stale").count() === 0, "one used 3 days ago isn't");
  const prov = await rows().filter({ hasText: "Docker" }).locator(".memory-source").textContent();
  check(/MF-391 builder on mbp-14 · for afomera · used 12×, 3d ago/.test(prov), `provenance reads "${prov}"`);

  await mkdir(proof, { recursive: true });
  await page.screenshot({ path: join(proof, "web-memory.png"), fullPage: true });

  // Kind.
  await page.locator('[data-kind="gotcha"]').click();
  await page.waitForFunction(() => location.hash.includes("kind=gotcha"));
  check(await shows(["npm test needs Docker running for the D1 shim."]), `kind Gotcha shows only the gotcha (${await texts()})`);
  await page.locator('[data-kind="all"]').click();
  await until(async () => await rows().count() === 3);

  // Repo.
  await page.getByTestId("memory-scope").selectOption("repo:acme/api");
  await page.waitForFunction(() => decodeURIComponent(location.hash).includes("scope=repo:acme/api"));
  check(await shows(["API handlers return { error } with a 4xx, never throw."]), `scope acme/api shows only its memory (${await texts()})`);
  check(!decodeURIComponent(page.url()).includes("kind="), "the scope keeps the kind filter (All)");
  await page.getByTestId("memory-scope").selectOption("repo:acme/web");
  await page.waitForFunction(() => decodeURIComponent(location.hash).includes("scope=repo:acme/web"));
  check(await until(async () => await rows().count() === 2), `scope acme/web shows its two active memories (${await rows().count()})`);

  // Proposed: Accept.
  await page.goto(`${base}/#/memory?status=proposed`);
  await page.getByTestId("memory-accept").click();
  await page.waitForFunction(() => !document.querySelector('[data-testid="memory-accept"]'));
  check(sent.some((m) => m.type === "memory.status" && m.id.endsWith("4") && m.status === "active"), "Accept sends memory.status active");

  // Edit.
  await page.goto(`${base}/#/memory?scope=repo:acme/api`);
  await page.getByTestId("memory-edit").click();
  await page.getByTestId("memory-edit-text").fill("API handlers return { error } with a 4xx; log 5xx to Sentry.");
  await page.getByTestId("memory-edit-tags").fill("api, Errors");
  await page.getByTestId("memory-save").click();
  await page.getByTestId("memory-text").filter({ hasText: "log 5xx to Sentry" }).waitFor();
  const edit = sent.find((m) => m.type === "memory.edit");
  check(edit?.text === "API handlers return { error } with a 4xx; log 5xx to Sentry." && JSON.stringify(edit.tags) === '["api","errors"]' && edit.kind === "convention",
    `Save sends memory.edit ${JSON.stringify(edit)}`);
  check(await page.locator(".memory-tags").textContent() === "#api#errors", "the row shows the new tags");

  // Archive.
  await page.goto(`${base}/#/memory`);
  await rows().filter({ hasText: "gh-pages" }).getByTestId("memory-archive").click();
  await page.waitForFunction(() => ![...document.querySelectorAll('[data-testid="memory-text"]')].some((e) => e.textContent.includes("gh-pages")));
  check(true, "Archive takes it off Active");
  await page.locator('[data-status="archived"]').click();
  await page.waitForFunction(() => location.hash.includes("status=archived"));
  check(await shows(["The marketing site deploys from the gh-pages branch."]), `it's under Archived (${await texts()})`);
  check(await rows().getByTestId("memory-restore").count() === 1, "with Restore");

  await page.goto(`${base}/#/memory`);

  // The task link in the provenance, and the task's timeline.
  await rows().filter({ hasText: "Docker" }).getByTestId("memory-task-link").click();
  await page.waitForFunction(() => location.hash === "#/t/MF-391");
  check(true, "the provenance's MF-391 opens #/t/MF-391");
  const item = page.getByTestId("timeline-memory");
  await item.waitFor();
  check((await item.textContent()).includes("Remembered 1 thing"), `the timeline says "${(await item.textContent()).trim()}"`);
  await item.scrollIntoViewIfNeeded();
  await page.screenshot({ path: join(proof, "web-timeline.png") });
  await item.getByRole("link").click();
  await page.waitForFunction(() => location.hash === "#/memory?task=MF-391");
  check(await until(async () => await rows().count() === 1 && (await page.getByTestId("memory-task-filter").count()) === 1), "and links to #/memory?task=MF-391, the one memory learned on it");

  // Settings › Repositories.
  await page.goto(`${base}/#/settings/repos`);
  const link = page.getByTestId("repo-memory-link").first();
  await link.waitFor();
  const labels = await page.getByTestId("repo-memory-link").allTextContents();
  check(JSON.stringify(labels) === JSON.stringify(["Memory (1)", "Memory (1)"]), `each repo links its memories (${labels})`);
  await link.click();
  await page.waitForFunction(() => decodeURIComponent(location.hash) === "#/memory?scope=repo:acme/api");
  check(await until(async () => await rows().count() === 1), "to #/memory?scope=repo:acme/api");

  check(pageErrors.length === 0, `no page errors (${pageErrors.join("; ") || "none"})`);
} catch (error) {
  console.log(`FAIL ${error.stack}`);
  if (pageErrors.length) console.log(`page errors: ${pageErrors.join("; ")}`);
  failures++;
} finally {
  await browser.close();
  files.close();
}
console.log(failures ? `${failures} failed` : `all passed · screenshots in ${proof}`);
process.exit(failures ? 1 : 0);
