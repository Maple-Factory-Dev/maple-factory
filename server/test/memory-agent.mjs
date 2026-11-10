#!/usr/bin/env node
// Stand-in for both `claude` and `codex` in e2e-memory-tools.mjs: no model, a real MCP client. It finds the
// `maple` MCP server in its own argv exactly where each CLI would (Claude Code: a `--mcp-config=<file>` JSON;
// Codex: `-c mcp_servers.maple.*` TOML overrides, started with only the environment `env_vars` names), spawns
// it over stdio and speaks JSON-RPC: initialize, tools/list, then remember → recall → forget. Every step goes
// to the JSONL log named by --fixture-log.
import { appendFileSync, readFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const argv = process.argv.slice(2);
const logAt = argv.indexOf("--fixture-log");
// The runner also runs an agent's command for its own probes (e.g. `<command> auth status`), without the
// fixture's arguments: that isn't a session, so say nothing and go.
if (logAt < 0 || !argv[logAt + 1]) process.exit(1);
const log = argv[logAt + 1];
const session = process.env.MAPLE_SESSION_ID;
const record = (type, data = {}) => appendFileSync(log, JSON.stringify({ session, type, ...data }) + "\n");

/** Where this CLI would find the maple server: { via, command, args, env }. */
function mapleServer() {
  for (const arg of argv) {
    if (!arg.startsWith("--mcp-config=")) continue;
    const server = JSON.parse(readFileSync(arg.slice("--mcp-config=".length), "utf8")).mcpServers?.maple;
    // Claude Code hands an MCP server its own environment.
    if (server) return { via: "claude --mcp-config", command: server.command, args: server.args ?? [], env: { ...process.env, ...(server.env ?? {}) } };
  }
  const overrides = {};
  for (let i = 0; i < argv.length - 1; i++) {
    const hit = (argv[i] === "-c" || argv[i] === "--config") && /^mcp_servers\.maple\.(\w+)=(.*)$/s.exec(argv[i + 1]);
    if (hit) overrides[hit[1]] = JSON.parse(hit[2]); // the runner writes these TOML values as JSON
  }
  if (overrides.command) {
    // Codex starts an MCP server with a minimal environment plus the variables `env_vars` lists.
    const env = { PATH: process.env.PATH, HOME: process.env.HOME };
    for (const name of overrides.env_vars ?? []) if (process.env[name] != null) env[name] = process.env[name];
    return { via: "codex -c mcp_servers.maple", command: overrides.command, args: overrides.args ?? [], env };
  }
  return null;
}

async function main() {
  const server = mapleServer();
  if (!server) throw new Error("no maple MCP server in argv");
  record("server", { via: server.via, args: server.args });
  const child = spawn(server.command, server.args, { env: server.env, stdio: ["pipe", "pipe", "inherit"] });
  const waiting = new Map();
  createInterface({ input: child.stdout }).on("line", (line) => {
    const msg = JSON.parse(line);
    waiting.get(msg.id)?.(msg);
    waiting.delete(msg.id);
  });
  let next = 0;
  const rpc = (method, params) => new Promise((resolve, reject) => {
    const id = ++next;
    const timer = setTimeout(() => reject(new Error(`${method} timed out`)), 30000);
    waiting.set(id, (msg) => { clearTimeout(timer); msg.error ? reject(new Error(`${method}: ${msg.error.message}`)) : resolve(msg.result); });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
  /** A tool's text, and the JSON after its summary line when there is some. */
  const tool = async (name, args) => {
    const result = await rpc("tools/call", { name, arguments: args });
    const text = result.content?.map((c) => c.text).join("\n") ?? "";
    if (result.isError) throw new Error(`${name}: ${text}`);
    const at = text.indexOf("\n\n");
    let data = null;
    try { data = at < 0 ? null : JSON.parse(text.slice(at + 2)); } catch {}
    record("call", { tool: name, summary: at < 0 ? text : text.slice(0, at), data });
    return data;
  };

  const init = await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "memory-agent", version: "1" } });
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
  record("initialized", { server: init.serverInfo?.name });
  const { tools } = await rpc("tools/list", {});
  record("tools", { names: tools.map((t) => t.name) });
  for (const name of ["recall", "remember", "forget"]) if (!tools.some((t) => t.name === name)) throw new Error(`${name} isn't listed`);

  const agent = process.env.MEMORY_AGENT_NAME ?? server.via.split(" ")[0];
  const text = `Fixture ${agent} learned that the widgets build needs the ${agent} toolchain pinned.`;
  const saved = await tool("remember", { text, kind: "gotcha", scope: "repo", tags: ["e2e", agent] });
  if (!saved?.id || saved.already) throw new Error("remember didn't save a new memory");
  const found = await tool("recall", { q: `${agent} toolchain pinned`, scope: "repo" });
  if (!found?.some((m) => m.id === saved.id && m.text === text)) throw new Error("recall didn't return what was remembered");
  const gone = await tool("forget", { id: saved.id, reason: `${agent} fixture is done with it` });
  if (gone?.status !== "archived") throw new Error("forget didn't archive it");
  const after = await tool("recall", { q: `${agent} toolchain pinned`, scope: "repo" });
  if (after?.some((m) => m.id === saved.id)) throw new Error("an archived memory was recalled");
  record("done", { memory: saved.id });
  child.stdin.end();
}

process.stdout.write("memory fixture running\r\n");
main().catch((error) => record("failed", { message: String(error?.message ?? error) })).finally(() => {
  process.stdout.write("memory fixture finished\r\n");
  // Stay up like an interactive CLI until the test ends the session.
  setInterval(() => {}, 1000);
  process.stdin.resume();
});
