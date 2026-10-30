#!/usr/bin/env node
// Isolated worker + real runner + private tmux, with no terminal viewer attached.
// node server/test/e2e-codex-startup.mjs [--installed] [--trust-test-repo] [--interactive] [--keep]
// Build runner first. Installed mode copies config/auth into a private CODEX_HOME;
// never prints either, and never changes the user's tmux, runner, or Codex state.
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, copyFileSync, readdirSync, rmSync, appendFileSync, realpathSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";
import WebSocket from "ws";

const root = fileURLToPath(new URL("../../", import.meta.url));
const installed = process.argv.includes("--installed");
const keep = process.argv.includes("--keep");
const dir = mkdtempSync(join(tmpdir(), "mf83-"));
const runnerBin = process.env.MAPLE_STARTUP_RUNNER ?? join(root, "runner/target/debug/maple-runner");
const tmux = process.env.MAPLE_TMUX ?? "tmux";
const socket = join(dir, "home/.config/maple/tmux/startup.sock");
const fixtureLog = join(dir, "fixture.jsonl");
const transcript = join(dir, "transcript.log");
const children = new Set();
let runner, worker, feed;
const machines = new Map(), tasks = new Map(), sessions = new Map(), ended = new Map();
const errors = [];
for (const signal of ["SIGTERM", "SIGINT"]) process.on(signal, () => errors.push(`interrupted by ${signal}`));
let goals = [], gotSnapshot = false;
const sanitize = (text) => String(text).replaceAll(realpathSync(dir), "<test>").replaceAll(dir, "<test>").replaceAll(homedir(), "<home>")
  .replace(/(?:mft|mfr)_[A-Za-z0-9_-]+/g, "<token>").replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
const report = (text) => {
  const line = `${new Date().toISOString()} ${sanitize(text)}`;
  console.log(line);
  appendFileSync(transcript, line + "\n");
};
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
  .filter((e) => (!id || e.session === id) && (!type || e.type === type));
const screen = (id) => {
  if (ended.has(id)) return ended.get(id).lastOutput.join("\n");
  try { return run(tmux, ["-S", socket, "capture-pane", "-p", "-t", `maple-${id}`]).trim(); }
  catch { return "<pane unavailable>"; }
};
async function stop(child) {
  if (!child?.pid || child.exitCode !== null || child.signalCode !== null) return;
  // Signal the test-owned group while its parent is still live. A completed
  // command's PID/group may have been reused, so never signal it after exit.
  try { process.kill(-child.pid, "SIGTERM"); } catch (error) { if (error.code !== "ESRCH") throw error; }
  const ended = once(child, "exit");
  await Promise.race([ended, pause(3000)]);
  if (child.exitCode === null && child.signalCode === null) {
    try { process.kill(-child.pid, "SIGKILL"); } catch (error) { if (error.code !== "ESRCH") throw error; }
    await ended;
  }
}
const send = (message) => feed.send(JSON.stringify(message));
let base, token, runnerToken;
async function request(path, body) {
  const res = await fetch(`${base}${path}`, { method: "POST", headers: { authorization: `Bearer ${token ?? ""}`, "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(10000) });
  const text = await res.text();
  if (!res.ok) throw new Error(`${path}: ${res.status} ${text}`);
  return text ? JSON.parse(text) : null;
}
async function startRunner() {
  runner = launch(runnerBin, ["run", "--url", base, "--token", runnerToken, "--runner-id", "startup", "--test", "--tmux-socket", "startup"], "runner", {
    HOME: join(dir, "home"), SHELL: "/bin/sh", CODEX_HOME: join(dir, "codex"),
  });
  await wait("runner online", () => machines.get("startup")?.online);
}
async function open(prompt, agent = "codex") {
  const before = new Set(sessions.keys());
  send({ type: "session.open", machine: "startup", agent, cwd: join(dir, "repo"), prompt, cols: 120, rows: 36 });
  return wait(`${agent} session`, () => [...sessions.keys()].find((id) => !before.has(id)));
}
// A bounded observation, followed by exactly one diagnostic Return. A deliberate
// trust/login/onboarding prompt is diagnosed without selecting anything in it.
async function observe(label, id, test, timeout = installed ? 60000 : 20000) {
  try {
    const result = await wait(label, () => {
      if (ended.has(id)) throw new Error(`session ended: ${ended.get(id).cause}, code=${ended.get(id).code}`);
      return test();
    }, timeout);
    report(`PASS ${label}; no intervention`); return result;
  }
  catch (error) {
    report(`TIMEOUT ${label}; last screen=${JSON.stringify(screen(id))}`);
    if (ended.has(id)) { report("Session lost; no diagnostic keys sent."); throw error; }
    if (/Trust this folder\?|Folder access|sign in to|log in to|onboarding|welcome to (?:Codex|ChatGPT)|update available/i.test(screen(id))) {
      report("Deliberate setup prompt detected; no Return sent.");
      throw error;
    }
    const before = screen(id);
    run(tmux, ["-S", socket, "send-keys", "-t", `maple-${id}`, "Enter"]);
    let changed = false;
    try { await wait(`${label} after diagnostic Return`, test, 5000); changed = true; } catch {}
    report(`controlled single Return: progressed=${changed}; screenChanged=${before !== screen(id)}; last screen=${JSON.stringify(screen(id))}`);
    throw error; // A diagnostic rescue must never make the regression pass.
  }
}
function rollouts() {
  const found = [];
  const walk = (path) => {
    if (!existsSync(path)) return;
    for (const entry of readdirSync(path, { withFileTypes: true })) {
      const file = join(path, entry.name);
      if (entry.isDirectory()) walk(file);
      else if (entry.name.endsWith(".jsonl")) {
        const rows = [];
        for (const line of readFileSync(file, "utf8").split("\n").filter(Boolean)) {
          try { rows.push(JSON.parse(line)); } catch {}
        }
        // Approval reviewers can write their own rollouts containing the parent's
        // transcript. Only the CLI conversation is delivery/assistant evidence.
        if (rows.find((e) => e.type === "session_meta")?.payload?.source === "cli") found.push(...rows);
      }
    }
  };
  walk(join(dir, "codex/sessions"));
  return found;
}
const assistantEvents = () => rollouts().filter((e) => e.type === "response_item" &&
  (e.payload?.role === "assistant" || ["function_call", "custom_tool_call"].includes(e.payload?.type))).length;
const completedTurns = () => rollouts().filter((e) => e.type === "event_msg" && e.payload?.type === "task_complete").length;

try {
  report(`mode=${installed ? "installed" : "fixture"}; ${run(tmux, ["-V"]).trim()}; node=${process.version}`);
  if (installed) report(run("codex", ["--version"], { stdio: ["ignore", "pipe", "ignore"] }).trim());
  else report("Codex stand-in; installed CLI behavior is a separate opt-in check");
  assert(existsSync(runnerBin), "Build first: cargo build --manifest-path runner/Cargo.toml");
  for (const folder of ["home/.config/maple", "codex", "repo"]) mkdirSync(join(dir, folder), { recursive: true });
  if (installed) {
    const source = process.env.CODEX_HOME ?? join(homedir(), ".codex");
    for (const file of ["auth.json", "config.toml"]) if (existsSync(join(source, file))) copyFileSync(join(source, file), join(dir, "codex", file));
  } else {
    const fixture = `command = ${JSON.stringify(join(root, "server/test/codex-startup-agent.mjs"))}\nargs = ["--fixture-log", ${JSON.stringify(fixtureLog)}, "--fixture-ready-ms", "1200"]\n`;
    writeFileSync(join(dir, "home/.config/maple/agents.toml"), `[agents.codex]\n${fixture}[agents.claude]\n${fixture}[agents.scripted]\ncommand = ${JSON.stringify(join(root, "server/test/scripted-agent.mjs"))}\nprompt = "positional"\n`);
  }
  run("git", ["init", "-q", "-b", "main", join(dir, "repo")]);
  writeFileSync(join(dir, "repo/README.md"), "Startup test repository.\n");
  const git = (...args) => run("git", ["-C", join(dir, "repo"), ...args]);
  git("config", "user.name", "Startup test"); git("config", "user.email", "startup@example.invalid");
  git("add", ".");
  git("-c", "user.name=Startup test", "-c", "user.email=startup@example.invalid", "commit", "-qm", "Initial fixture");
  run("git", ["clone", "--bare", "-q", join(dir, "repo"), join(dir, "origin.git")]);
  git("remote", "add", "origin", join(dir, "origin.git"));
  git("fetch", "-q", "origin");
  if (installed && process.argv.includes("--trust-test-repo")) {
    // Explicit test setup in the copied config, not a keystroke dismissing a live prompt.
    appendFileSync(join(dir, "codex/config.toml"), `\n[projects.${JSON.stringify(realpathSync(join(dir, "repo")))}]\ntrust_level = "trusted"\n`);
    report("test-owned repository explicitly trusted in private Codex config before launch");
  }
  // Use a fresh worker config, storage, port, and runner HOME for every invocation.
  const config = join(dir, "wrangler.json");
  writeFileSync(config, JSON.stringify({ name: "mf83-startup", main: join(root, "server/src/index.ts"), compatibility_date: "2026-09-01",
    assets: { directory: join(root, "server/web") }, vars: { DEV_LOGIN: "startup", GITHUB_ORG: "", SESSION_SECRET: "startup-test-only", MERGE_GRACE_MS: "100" },
    durable_objects: { bindings: [{ name: "ORG", class_name: "OrgHub" }, { name: "MACHINE", class_name: "MachineHub" }] },
    migrations: [{ tag: "v1", new_sqlite_classes: ["OrgHub", "MachineHub"] }],
    d1_databases: [{ binding: "DB", database_name: "maple", database_id: "00000000-0000-0000-0000-000000000000", migrations_dir: join(root, "server/migrations") }],
    r2_buckets: [{ binding: "RELEASES", bucket_name: "startup-releases" }],
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
  ({ token: runnerToken } = await request("/runner/enroll", { code, runnerId: "startup", hostname: "startup", os: "macos", arch: process.arch, version: "0.44.0", test: true }));
  feed = new WebSocket(`${base.replace("http", "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  feed.on("message", (data) => {
    const m = JSON.parse(String(data));
    if (m.type === "snapshot") { goals = m.goals; gotSnapshot = true; for (const machine of m.machines) machines.set(machine.id, machine); for (const t of m.tasks) tasks.set(t.id, t); }
    if (m.type === "machine.updated") machines.set(m.machine.id, m.machine);
    if (m.type === "goal.updated") { goals = goals.filter((g) => g.id !== m.goal.id); goals.push(m.goal); }
    if (m.type === "task.updated") tasks.set(m.task.id, m.task);
    if (m.type === "session.ended") ended.set(m.end.id, m.end);
    if (m.type === "error") errors.push(m.message);
    for (const machine of machines.values()) for (const live of machine.sessions) sessions.set(live.session.id, live);
  });
  feed.on("error", (error) => errors.push(`client: ${error.message}`));
  await wait("client connection", () => feed.readyState === WebSocket.OPEN); send({ type: "subscribe" });
  await wait("snapshot", () => gotSnapshot);
  await startRunner();
  report("isolated worker and runner online; terminal viewers=0");

  if (!installed) {
    const prompts = ["short 'quotes' $HOME `ticks` \\", "two lines\nsecond line", "file-backed\n" + "x".repeat(1100) + "\nlast 'line' $HOME `ticks` \\", "file trailing newline\n" + "x".repeat(1100) + "\n\n"];
    for (const prompt of prompts) {
      const id = await open(prompt);
      await observe(`initial prompt ${Buffer.byteLength(prompt)} bytes`, id, () => events(id, "submission").length === 1);
      assert.equal(events(id, "submission")[0].text, prompt);
      assert.equal(events(id, "input").length, 0, "startup must not inject keys");
      report(`argv exactly once; transport=${Buffer.byteLength(prompt) > 1024 ? "file" : "argv"}`);
    }
    const blank = await open("  ");
    await wait("blank ready", () => events(blank, "ready").length);
    assert.equal(events(blank, "submission").length, 0); assert.equal(events(blank, "input").length, 0);
    report("PASS blank prompt: no submission or startup keys");
    const claude = await open("Claude launch control", "claude");
    await observe("Claude launch control", claude, () => events(claude, "submission").length === 1);
    assert.equal(events(claude, "submission")[0].text, "Claude launch control");
    assert.equal(events(claude, "input").length, 0);
  }

  send({ type: "goal.save", goal: { id: "", name: "Codex startup", prefix: "BOOT", color: "#2EA043", summary: "Isolated startup investigation", lead: "", folder: join(dir, "repo"), base: "main" } });
  const goal = await wait("goal", () => goals.find((g) => g.prefix === "BOOT"));
  const baseline = installed ? assistantEvents() : 0;
  send({ type: "task.create", goal: goal.id, title: "Startup greeting question", brief: "Ask which greeting is required using the ask tool with Casual and Formal options. After the answer, acknowledge it and wait for steering; do not submit a plan yet.", shareable: false, plan: true, tickets: [], agent: "codex" });
  const task = await wait("factory planner session", () => [...tasks.values()].find((t) => t.worker?.role === "planner"), 30000);
  const id = task.worker.session;
  await wait("factory session opened on runner", () => sessions.has(id), 30000);
  report(`factory planner opened; ${installed ? "observing rollout assistant/tool events" : "observing fixture submissions"}`);
  if (installed) await observe("first assistant/tool event", id, () => assistantEvents() > baseline);
  else {
    await observe("factory initial instruction", id, () => events(id, "submission").length === 1);
    assert.equal(events(id, "input").length, 0, "factory startup must not inject keys");
  }
  if (installed) await observe("initial turn completed", id, () => completedTurns() > 0);
  if (!installed || tasks.get(task.id)?.question) {
    await observe("planner asks through MCP", id, () => tasks.get(task.id)?.question);
    const first = installed ? assistantEvents() : events(id, "submission").length;
    send({ type: "task.answer", id: task.id, text: "Casual\nKeep both lines." });
    await observe("factory answer", id, () => installed ? assistantEvents() > first : events(id, "submission").length === first + 1);
    if (!installed) assert(events(id, "submission").at(-1).text.includes("Casual\nKeep both lines."));
    if (installed) await observe("answer turn completed", id, () => completedTurns() > 1);
  } else {
    report(`UNRESOLVED real factory answer: planner did not create a factory question; last screen=${JSON.stringify(screen(id))}`);
    report("Continuing the independent factory steering check; MCP approval settings are unchanged.");
  }
  const second = installed ? assistantEvents() : events(id, "submission").length;
  const steerText = installed
    ? "For this startup smoke test, reply with STEER_RECEIVED and end your turn. Do not inspect or modify files or call tools.\nKeep this second line in the message."
    : "Keep the greeting short.\nPreserve the second line.";
  send({ type: "task.steer", id: task.id, text: steerText });
  await observe("factory steer", id, () => installed ? assistantEvents() > second : events(id, "submission").length === second + 1);
  if (!installed) assert(events(id, "submission").at(-1).text.includes("Keep the greeting short.\nPreserve the second line."));
  if (installed) {
    const delivered = rollouts().filter((e) => e.type === "response_item" && e.payload?.role === "user" && e.payload.content?.some((c) => c.text?.includes(steerText)));
    assert.equal(delivered.length, 1, "factory steering must arrive once");
    report(`PASS installed steering: CLI user messages=${delivered.length}; completed turns=${completedTurns()}; assistant/tool events=${assistantEvents()}`);
  }
  if (!installed) {
    for (const [choice, bytes] of [["yes", "1"], ["no", "\x1b"]]) {
      const at = events(id, "input").length;
      const submissions = events(id, "submission").length;
      const previousActivity = sessions.get(id)?.activity?.at ?? 0;
      // Simulate an agent's permission hook, then exercise the real factory keys:true route.
      run(runnerBin, ["hook", "claude"], { env: { ...process.env, MAPLE_SESSION_ID: id, MAPLE_HOOK_SOCKET: join(dir, "home/.config/maple/runner-startup.sock") },
        input: JSON.stringify({ hook_event_name: "PermissionRequest", tool_name: "Bash", tool_input: { command: "echo fixture" } }) });
      await wait("permission activity", () => sessions.get(id)?.activity?.at > previousActivity && sessions.get(id)?.activity?.question?.permission);
      send({ type: "task.answerPrompt", id: task.id, choice });
      await wait("permission bytes", () => events(id, "input").length > at);
      await pause(500);
      const received = events(id, "input").slice(at).map((e) => Buffer.from(e.base64, "base64").toString()).join("");
      assert.equal(received, bytes, "permission keys get no paste markers or Return");
      assert.equal(events(id, "submission").length, submissions);
      report(`PASS raw permission choice ${choice}; no added Return or submission`);
    }
  }
  const before = events(null, "input").length;
  const submittedBefore = installed ? 0 : events(null, "submission").length;
  const usersBefore = installed ? rollouts().filter((e) => e.type === "response_item" && e.payload?.role === "user").length : 0;
  await stop(runner);
  await wait("runner offline", () => !machines.get("startup")?.online);
  await startRunner();
  await wait("adopted planner", () => machines.get("startup")?.sessions.some((s) => s.session.id === id));
  await pause(1500);
  if (!installed) {
    assert.equal(events(null, "input").length, before, "adoption cannot inject startup input");
    assert.equal(events(null, "submission").length, submittedBefore, "adoption cannot resubmit any prompt");
  } else assert.equal(rollouts().filter((e) => e.type === "response_item" && e.payload?.role === "user").length, usersBefore, "adoption cannot resubmit a CLI message");
  report(`PASS adoption; ${installed ? "planner remains live" : "no extra terminal input or submission"}`);
  report(`last screen=${JSON.stringify(screen(id))}`);
  report(installed && !tasks.get(task.id)?.question ? "PASS startup/steering observations; real factory answer remains unresolved" : "PASS startup matrix");
  if (!installed && process.argv.includes("--interactive")) {
    send({ type: "task.cancel", id: task.id });
    await wait("cancel fixture planner", () => tasks.get(task.id)?.state === "cancelled");
    // The legacy scripts expect a WebSocket implementation with the `headers` option.
    const loader = join(dir, "websocket.mjs");
    writeFileSync(loader, `import WebSocket from ${JSON.stringify(join(root, "node_modules/ws/wrapper.mjs"))}; globalThis.WebSocket = WebSocket;\n`);
    for (const name of ["e2e-local", "e2e-interactive", "e2e-steer"]) {
      const args = name === "e2e-local" ? [base, "startup"] : [base, "BOOT", join(dir, "repo")];
      const child = launch(process.execPath, ["--import", loader, join(root, `server/test/${name}.mjs`), ...args], name);
      await wait(name, () => child.exitCode !== null, 240000);
      report(`${name}:\n${readFileSync(join(dir, `${name}.log`), "utf8")}`);
      assert.equal(child.exitCode, 0, name);
    }
  }
} catch (error) {
  report(`FAIL ${error.stack}`);
  for (const [id] of sessions) report(`diagnostic screen=${JSON.stringify(screen(id))}`);
  for (const name of ["migration", "worker", "runner"]) if (existsSync(join(dir, `${name}.log`))) report(`${name} log tail=${readFileSync(join(dir, `${name}.log`), "utf8").split("\n").slice(-12).join("\n")}`);
  process.exitCode = 1;
} finally {
  const cleanup = async (child) => {
    try { await stop(child); }
    catch (error) { report(`CLEANUP FAILED: ${error.message}`); process.exitCode = 1; }
  };
  feed?.close();
  await cleanup(runner);
  if (existsSync(socket)) { try { run(tmux, ["-S", socket, "kill-server"]); } catch {} }
  await cleanup(worker);
  for (const child of [...children]) await cleanup(child);
  for (const file of ["auth.json", "config.toml"]) rmSync(join(dir, "codex", file), { force: true });
  if (keep) console.log(`Artifacts: ${dir}`);
  else rmSync(dir, { recursive: true, force: true });
}
