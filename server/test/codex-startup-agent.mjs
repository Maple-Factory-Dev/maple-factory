#!/usr/bin/env node
// Raw-TTY fixture for the built-in codex override. No model, no line-buffered stdin.
// Only an argv prompt or Return outside bracketed paste completes a submission.
import { appendFileSync } from "node:fs";
import net from "node:net";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const at = args.indexOf(name);
  return at < 0 ? fallback : args.splice(at, 2)[1];
};
const log = option("--fixture-log", process.env.CODEX_FIXTURE_LOG);
const readyMs = Number(option("--fixture-ready-ms", "800"));
const pasteMs = Number(option("--fixture-paste-ms", "80"));
if (!log || !process.stdin.isTTY) throw new Error("fixture requires --fixture-log and a TTY");
const record = (type, data = {}) => appendFileSync(log, JSON.stringify({ at: new Date().toISOString(), session: process.env.MAPLE_SESSION_ID, type, ...data }) + "\n");
record("argv", { args });
process.stdin.setRawMode(true);
process.stdin.setEncoding("utf8");
process.stdout.write("fixture booting\r\n");
let ready = false, pending = "", editing = "", pasting = false, pasteEnded = 0, count = 0;

function call(tool, args) {
  return new Promise((resolve, reject) => {
    const conn = net.createConnection(process.env.MAPLE_HOOK_SOCKET);
    let reply = "";
    conn.on("error", reject);
    conn.on("data", (d) => { reply += d; });
    conn.on("end", () => {
      try { const result = JSON.parse(reply); if (result.error) throw new Error(result.error); resolve(result); }
      catch (error) { reject(error); }
    });
    conn.end(JSON.stringify({ mcp: { session: process.env.MAPLE_SESSION_ID, tool, args } }) + "\n");
  });
}

function submit(text, origin) {
  record("submission", { count: ++count, origin, text });
  process.stdout.write(`submitted ${count} (${origin})\r\n`);
  if (origin === "argv" && text.includes("You are the planner")) {
    call("ask", { question: "Startup fixture is ready. Which greeting?", options: ["Casual", "Formal"] })
      .then(() => record("asked"), (error) => record("hook-error", { message: String(error) }));
  }
}

// Retain partial escape markers between reads. Newlines *inside* a paste are text.
function drain() {
  while (pending) {
    const marker = pasting ? "\x1b[201~" : "\x1b[200~";
    if (marker.startsWith(pending) && pending.length < marker.length) return;
    if (pending.startsWith(marker)) {
      pending = pending.slice(marker.length);
      pasting = !pasting;
      record(pasting ? "paste-start" : "paste-end");
      if (!pasting) pasteEnded = Date.now();
      continue;
    }
    const char = pending[0];
    pending = pending.slice(1);
    if (!pasting && (char === "\r" || char === "\n")) {
      if (Date.now() - pasteEnded < pasteMs) {
        editing += "\n";
        record("return-during-paste-settle");
      } else {
        record("return", { blank: !editing.trim() });
        if (editing.trim()) submit(editing, "tty");
        editing = "";
      }
    } else if (char === "\x03") process.exit(0);
    else editing += char;
  }
}
process.stdin.on("data", (chunk) => {
  record("input", { ready, base64: Buffer.from(chunk).toString("base64") });
  pending += chunk;
  if (ready) drain();
});
setTimeout(() => {
  ready = true;
  record("ready");
  process.stdout.write("\x1b[?2004hfixture ready\r\n");
  // Runner flags precede the supplied prompt. Blank prompts have no positional argument.
  const optionsWithValue = new Set(["-c", "--config", "--model", "-m", "--sandbox", "--ask-for-approval", "--settings"]);
  const positional = [];
  for (let i = 0; i < args.length; i++) {
    if (optionsWithValue.has(args[i])) i++;
    else if (!args[i].startsWith("-") && args[i] !== "resume") positional.push(args[i]);
  }
  if (positional.length) submit(positional.at(-1), "argv");
  drain();
}, readyMs);
