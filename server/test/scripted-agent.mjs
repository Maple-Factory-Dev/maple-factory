#!/usr/bin/env node
// A stand-in for Claude Code in factory tests: it reads its role from the prompt and plays it
// through the same `maple` tools a real agent calls (over the runner's hook socket), without a model.
//
//   ~/.config/maple/agents.toml:
//     [agents.scripted]
//     command = "/path/to/server/test/scripted-agent.mjs"
//     prompt = "positional"
//
// Planner: submits a two-step plan with a terminal and a screen mockup. Builder: commits a file,
// proves both items and finishes. Reviewer: asks for changes in round 1, passes round 2.

import net from "node:net";
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const prompt = process.argv.at(-1) ?? "";
const session = process.env.MAPLE_SESSION_ID;
const socket = process.env.MAPLE_HOOK_SOCKET;
const say = (line) => console.log(`\x1b[2m·\x1b[0m ${line}`);

function call(tool, args = {}) {
  return new Promise((resolve, reject) => {
    const conn = net.createConnection(socket);
    let reply = "";
    conn.on("data", (d) => (reply += d));
    conn.on("end", () => {
      const msg = JSON.parse(reply);
      if (msg.error) reject(new Error(`${tool}: ${msg.error}`));
      else resolve(msg.result);
    });
    conn.on("error", reject);
    conn.end(JSON.stringify({ mcp: { session, tool, args } }) + "\n");
  });
}

const git = (...args) => execFileSync("git", args, { encoding: "utf8" }).trim();

async function planner() {
  say("reading the code");
  const { data } = await call("get_task");
  const plan = await call("submit_plan", {
    summary: `Add a greeting file for ${data.task.id}, so the factory has something real to commit, push and merge.`,
    steps: [
      { text: "Write hello.txt with a greeting", file: "hello.txt" },
      { text: "Commit it on the task branch", file: "hello.txt" },
    ],
    doneWhen: [
      { text: "hello.txt says hello", proof: "terminal" },
      { text: "The branch has the commit", proof: "terminal" },
    ],
    risk: { level: "low", reasons: ["One new text file."], areas: [] },
    footprint: { files: 1, lines: 1 },
    mockups: [
      {
        title: "cat hello.txt",
        kind: "terminal",
        lines: [
          { text: "$ cat hello.txt", style: "command" },
          { text: `hello from ${data.task.id}`, style: "highlight", callout: 1 },
        ],
        notes: ["The greeting names the task."],
      },
      {
        title: "Greeting page",
        kind: "screen",
        url: "localhost:3000/hello",
        html: `<body style="font:15px -apple-system;margin:0;display:grid;place-items:center;height:100vh;background:#faf7f5">
          <div style="padding:28px 36px;border-radius:14px;background:white;box-shadow:0 8px 30px #0001">
          <h1 style="margin:0 0 6px;font-size:22px">Hello from ${data.task.id}</h1>
          <p style="margin:0;color:#777">① The greeting names the task.</p></div></body>`,
        notes: ["The greeting names the task."],
      },
    ],
  });
  say(plan.summary);
}

async function builder() {
  const { data } = await call("get_task");
  const fixing = /asked for changes/.test(prompt);
  await call("progress", { step: 1, status: "active", note: fixing ? "Fixing the review's findings" : "Writing hello.txt" });
  writeFileSync("hello.txt", `hello from ${data.task.id}${fixing ? "\n(with a trailing newline, as review asked)" : ""}\n`);
  await call("progress", { step: 1, status: "done" });
  await call("progress", { step: 2, status: "active", note: "Committing" });
  git("add", "hello.txt");
  git("-c", "user.name=Scripted", "-c", "user.email=scripted@maple.invalid", "commit", "-qm", fixing ? "Address review" : "Add hello.txt");
  await call("progress", { step: 2, status: "done" });
  const applied = [...prompt.matchAll(/- \((C\d+)\)/g)].map((m) => m[1]);
  if (applied.length) await call("progress", { applied });
  await call("prove", { item: 1, kind: "terminal", summary: "hello.txt has the greeting", command: "cat hello.txt", output: git("show", "HEAD:hello.txt").split("\n") });
  await call("prove", { item: 2, kind: "terminal", summary: "The commit is on the branch", command: "git log --oneline -3", output: git("log", "--oneline", "-3").split("\n") });
  const done = await call("finish", { summary: fixing ? "Addressed the review's finding." : "Added hello.txt with the task's greeting." });
  say(done.summary);
}

async function reviewer() {
  const open = [...prompt.matchAll(/- \((R\d+\.\d+)\)/g)].map((m) => m[1]);
  const first = !/Open findings from earlier rounds/.test(prompt);
  const verdict = first ? "changesRequested" : "passed";
  const review = await call("submit_review", {
    verdict,
    summary: first ? "Does what it says, but the file should end with a note." : "The finding is fixed; good to go.",
    ask: [{ text: "Add a greeting file", verdict: "met" }],
    proofs: [
      { text: "hello.txt says hello", verdict: "met" },
      { text: "The branch has the commit", verdict: "met" },
    ],
    findings: first ? [{ kind: "code", severity: "major", text: "Add a second line saying it was reviewed.", file: "hello.txt:1" }] : [],
    fixed: first ? [] : open,
  });
  say(review.summary);
}

try {
  if (/You are the planner/.test(prompt)) await planner();
  else if (/You are the builder/.test(prompt)) await builder();
  else if (/You are the review agent/.test(prompt)) await reviewer();
  else say("no factory role in the prompt");
} catch (e) {
  console.error(String(e));
}
// Stay up like an agent waiting for input; the factory closes the session.
setInterval(() => {}, 1 << 30);
