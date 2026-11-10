#!/usr/bin/env node
// MF-392, end to end: an isolated wrangler dev worker, the real runner in a private HOME and tmux, and a
// fixture agent (memory-agent.mjs) standing in for both `claude` and `codex`. Each fixture session finds the
// `maple` MCP server the way its CLI would, lists the tools and runs remember → recall → forget over MCP stdio,
// so this proves the runner's `maple-runner mcp` passes the factory-listed memory tools through unchanged.
// node server/test/e2e-memory-tools.mjs [--keep]      (build first: cargo build --manifest-path runner/Cargo.toml)
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";
import WebSocket from "ws";

const root = fileURLToPath(new URL("../../", import.meta.url));
const keep = process.argv.includes("--keep");
const dir = mkdtempSync(join(tmpdir(), "mf392-"));
const runnerBin = process.env.MAPLE_STARTUP_RUNNER ?? join(root, "runner/target/debug/maple-runner");
const tmux = process.env.MAPLE_TMUX ?? "tmux";
const socket = join(dir, "home/.config/maple/tmux/memory.sock");
const fixtureLog = join(dir, "fixture.jsonl");
const REPO = "acme/widgets";
// A folder named like the org repo: …/acme/widgets.
const checkout = join(dir, "code/acme/widgets");
const children = new Set();
const errors = [];
const machines = new Map(), memories = new Map(), deliveries = [];
let runner, worker, feed, repos = [], gotSnapshot = false, base, token, runnerToken;
const report = (text) => console.log(String(text).replaceAll(dir, "<test>").replace(/(?:mft|mfr)_[A-Za-z0-9_-]+/g, "<token>"));
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const run = (bin, args, options = {}) => execFileSync(bin, args, { encoding: "utf8", timeout: 60000, ...options });
function launch(bin, args, name, env = {}) {
  const child = spawn(bin, args, { cwd: root, detached: true, env: { ...process.env, HOME: join(dir, "home"), XDG_CONFIG_HOME: join(dir, "home/.config"), ...env }, stdio: ["ignore", "pipe", "pipe"] });
  children.add(child);
  child.on("exit", () => children.delete(child));
  child.on("error", (error) => errors.push(`${name}: ${error.message}`));
  for (const stream of [child.stdout, child.stderr]) stream.on("data", (data) => appendFileSync(join(dir, `${name}.log`), data));
  return child;
}
async function wait(label, test, ms = 20000) {
  const until = Date.now() + ms;
  do {
    const hit = await test();
    if (hit) return hit;
    if (errors.length) throw new Error(errors.join("; "));
    await pause(100);
  } while (Date.now() < until);
  throw new Error(`timeout: ${label}`);
}
const events = (id, type) => (existsSync(fixtureLog) ? readFileSync(fixtureLog, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [])
  .filter((e) => e.session === id && (!type || e.type === type));
async function stop(child) {
  if (!child?.pid || child.exitCode !== null || child.signalCode !== null) return;
  try { process.kill(-child.pid, "SIGTERM"); } catch (error) { if (error.code !== "ESRCH") throw error; }
  const ended = once(child, "exit");
  await Promise.race([ended, pause(3000)]);
  if (child.exitCode === null && child.signalCode === null) {
    try { process.kill(-child.pid, "SIGKILL"); } catch (error) { if (error.code !== "ESRCH") throw error; }
    await ended;
  }
}
const send = (message) => feed.send(JSON.stringify(message));
async function request(path, body) {
  const res = await fetch(`${base}${path}`, { method: "POST", headers: { authorization: `Bearer ${token ?? ""}`, "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(10000) });
  const text = await res.text();
  if (!res.ok) throw new Error(`${path}: ${res.status} ${text}`);
  return text ? JSON.parse(text) : null;
}

try {
  report(`${run(tmux, ["-V"]).trim()}; node=${process.version}`);
  assert(existsSync(runnerBin), "Build first: cargo build --manifest-path runner/Cargo.toml");
  for (const folder of ["home/.config/maple", "codex", "code/acme/widgets"]) mkdirSync(join(dir, folder), { recursive: true });
  // One fixture for both built-in agents: the runner still wires each the way it wires the real CLI.
  const fixture = `command = ${JSON.stringify(join(root, "server/test/memory-agent.mjs"))}\nargs = ["--fixture-log", ${JSON.stringify(fixtureLog)}]\n`;
  writeFileSync(join(dir, "home/.config/maple/agents.toml"), `[agents.codex]\n${fixture}[agents.claude]\n${fixture}`);
  run("git", ["init", "-q", "-b", "main", checkout]);

  const config = join(dir, "wrangler.json");
  writeFileSync(config, JSON.stringify({ name: "mf392-memory", main: join(root, "server/src/index.ts"), compatibility_date: "2026-09-01",
    assets: { directory: join(root, "server/web") }, vars: { DEV_LOGIN: "memory", GITHUB_ORG: "", SESSION_SECRET: "memory-test-only" },
    durable_objects: { bindings: [{ name: "ORG", class_name: "OrgHub" }, { name: "MACHINE", class_name: "MachineHub" }] },
    migrations: [{ tag: "v1", new_sqlite_classes: ["OrgHub", "MachineHub"] }],
    d1_databases: [{ binding: "DB", database_name: "maple", database_id: "00000000-0000-0000-0000-000000000000", migrations_dir: join(root, "server/migrations") }],
    r2_buckets: [{ binding: "RELEASES", bucket_name: "memory-releases" }],
  }));
  const wrangler = join(root, "node_modules/wrangler/wrangler-dist/cli.js");
  const migration = launch(process.execPath, [wrangler, "d1", "migrations", "apply", "maple", "--local", "--config", config, "--persist-to", join(dir, "state")], "migration", { WRANGLER_SEND_METRICS: "false" });
  await wait("isolated migrations", () => migration.exitCode !== null, 60000);
  assert.equal(migration.exitCode, 0, "isolated migrations");
  const listener = net.createServer(); listener.listen(0, "127.0.0.1"); await once(listener, "listening");
  const port = listener.address().port; await new Promise((r) => listener.close(r));
  base = `http://localhost:${port}`;
  worker = launch(process.execPath, [wrangler, "dev", "--config", config, "--persist-to", join(dir, "state"), "--port", String(port)], "worker", { WRANGLER_SEND_METRICS: "false" });
  await wait("worker", async () => { try { return (await fetch(`${base}/healthz`, { signal: AbortSignal.timeout(1000) })).ok; } catch { return false; } }, 30000);
  ({ token } = await request("/dev/token"));
  const { code } = await request("/api/machines/enroll");
  ({ token: runnerToken } = await request("/runner/enroll", { code, runnerId: "memory", hostname: "memory-host", os: "macos", arch: process.arch, version: "0.44.0", test: true }));
  feed = new WebSocket(`${base.replace("http", "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  feed.on("message", (data) => {
    const m = JSON.parse(String(data));
    if (m.type === "snapshot") { gotSnapshot = true; repos = m.repos ?? []; for (const machine of m.machines) machines.set(machine.id, machine); }
    if (m.type === "machine.updated") machines.set(m.machine.id, m.machine);
    if (m.type === "repos.updated") repos = m.repos;
    if (m.type === "memory.updated") { memories.set(m.memory.id, m.memory); deliveries.push(m.memory); }
    if (m.type === "memory.removed") errors.push(`a memory was deleted: ${m.id}`);
    if (m.type === "error") errors.push(m.message);
  });
  feed.on("error", (error) => errors.push(`client: ${error.message}`));
  await wait("client connection", () => feed.readyState === WebSocket.OPEN); send({ type: "subscribe" });
  await wait("snapshot", () => gotSnapshot);
  send({ type: "repos.add", name: REPO });
  await wait("org repo", () => repos.some((r) => r.name === REPO));
  runner = launch(runnerBin, ["run", "--url", base, "--token", runnerToken, "--runner-id", "memory", "--test", "--tmux-socket", "memory"], "runner", {
    HOME: join(dir, "home"), SHELL: "/bin/sh", CODEX_HOME: join(dir, "codex"),
  });
  const machine = await wait("runner online", () => machines.get("memory")?.online && machines.get("memory"));
  report(`isolated worker and real runner online as machine "${machine.name}"; org repo ${REPO}; sessions open in <test>/code/acme/widgets`);

  for (const agent of ["claude", "codex"]) {
    const before = new Set([...machines.values()].flatMap((m) => m.sessions.map((s) => s.session.id)));
    send({ type: "session.open", machine: "memory", agent, cwd: checkout, prompt: "", cols: 120, rows: 36 });
    const id = await wait(`${agent} session`, () => machines.get("memory").sessions.map((s) => s.session.id).find((s) => !before.has(s)));
    await wait(`${agent} fixture finished`, () => events(id, "done").length || events(id, "failed").length, 60000);
    assert.deepEqual(events(id, "failed"), [], `${agent} fixture`);
    const via = events(id, "server")[0].via;
    assert.equal(via, agent === "claude" ? "claude --mcp-config" : "codex -c mcp_servers.maple", "found the maple server the way this CLI does");
    assert.equal(events(id, "initialized")[0].server, "maple");
    const names = events(id, "tools")[0].names;
    for (const name of ["recall", "remember", "forget"]) assert(names.includes(name), `${agent} lists ${name}`);
    const calls = events(id, "call");
    assert.deepEqual(calls.map((c) => c.tool), ["remember", "recall", "forget", "recall"]);
    const memory = events(id, "done")[0].memory;
    assert.equal(calls[0].data.id, memory);
    assert.equal(calls[1].data.length, 1); assert.equal(calls[1].data[0].id, memory);
    assert.equal(calls[1].data[0].scope, "repo");
    assert.deepEqual(calls[2].data, { id: memory, status: "archived" });
    assert.deepEqual(calls[3].data, []);
    // The feed: created active with the cwd's repo as its scope, then archived (never removed).
    await wait(`${agent} memory archived on the feed`, () => memories.get(memory)?.status === "archived");
    const seen = deliveries.filter((m) => m.id === memory);
    assert.deepEqual(seen.map((m) => m.status), ["active", "archived"]);
    assert.deepEqual(seen[0].scope, { kind: "repo", key: REPO });
    assert.equal(seen[0].kind, "gotcha");
    assert.deepEqual(seen[0].tags, ["e2e", agent]);
    assert.equal(seen[0].source.by, "memory");
    assert.equal(seen[0].source.machine, machine.name);
    assert.equal(seen[0].source.agent, `${agent} on ${machine.name}`);
    assert.equal(seen[0].source.task, null);
    report(`PASS ${agent}: via ${via}; tools/list has recall, remember, forget (${names.length} tools)`);
    for (const c of calls) report(`  ${agent} ${c.tool} → ${c.summary}`);
    report(`  feed: memory.updated ${memory} scope=${JSON.stringify(seen[0].scope)} source.machine=${seen[0].source.machine} source.agent="${seen[0].source.agent}" → status ${seen.map((m) => m.status).join(" → ")}`);
  }
  assert.equal(deliveries.length, 4);
  assert.deepEqual(errors, []);
  report("PASS memory tools end to end: claude and codex sessions each listed and called recall, remember and forget through the real runner");
} catch (error) {
  report(`FAIL ${error.stack}`);
  if (existsSync(fixtureLog)) report(`fixture log=${readFileSync(fixtureLog, "utf8")}`);
  for (const name of ["migration", "worker", "runner"]) if (existsSync(join(dir, `${name}.log`))) report(`${name} log tail=${readFileSync(join(dir, `${name}.log`), "utf8").split("\n").slice(-12).join("\n")}`);
  process.exitCode = 1;
} finally {
  const cleanup = async (child) => { try { await stop(child); } catch (error) { report(`CLEANUP FAILED: ${error.message}`); process.exitCode = 1; } };
  feed?.close();
  await cleanup(runner);
  if (existsSync(socket)) { try { run(tmux, ["-S", socket, "kill-server"]); } catch {} }
  await cleanup(worker);
  for (const child of [...children]) await cleanup(child);
  if (keep) console.log(`Artifacts: ${dir}`);
  else rmSync(dir, { recursive: true, force: true });
}
