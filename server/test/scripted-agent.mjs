#!/usr/bin/env node
// A stand-in for Claude Code in factory tests: it reads its role from the prompt and plays it
// through the same `maple` tools a real agent calls (over the runner's hook socket), without a model.
//
//   ~/.config/maple/agents.toml:
//     [agents.scripted]
//     command = "/path/to/server/test/scripted-agent.mjs"
//     prompt = "positional"
//
// Planner: submits a two-step plan with a terminal and a screen mockup ("[cross-repo]": plus a part
// for the goal's next repo). Builder: commits a file,
// proves both items and finishes ("## It didn't merge": merges its base in and resolves the conflicts;
// "[attest]": waits for a person to attest to both items first, then proves them anyway).
// Reviewer: asks for changes in round 1, passes round 2.

import net from "node:net";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

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

// What a person types into the session (answers, decisions, change requests), a line at a time,
// without the bracketed-paste markers the factory wraps it in.
const typed = [];
let wake = null;
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  for (const line of chunk.replace(/\x1b\[20[01]~/g, "").split(/\r|\n/)) if (line.trim()) typed.push(line.trim());
  wake?.();
});
async function nextLine() {
  while (!typed.length) await new Promise((r) => (wake = r));
  const line = typed.shift();
  say(`got: ${line}`);
  return line;
}

const git = (...args) => execFileSync("git", args, { encoding: "utf8" }).trim();

async function planner() {
  say("reading the code");
  const { data } = await call("get_task");
  let answer = "";
  if (prompt.includes("[ask]") && !/answered/.test(data.task.comments.map((c) => c.anchor ?? "").join(" ") + prompt)) {
    await call("ask", { question: "Formal or casual greeting?", options: ["Formal", "Casual"] });
    answer = await nextLine();
  }
  const rename = prompt.match(/\[rename: ([^\]]+)\]/);
  const plan = await call("submit_plan", {
    summary: `Add a greeting file for ${data.task.id}, so the factory has something real to commit, push and merge.${answer ? ` (${answer})` : ""}`,
    steps: [
      { text: "Write hello.txt with a greeting", file: "hello.txt" },
      { text: "Commit it on the task branch", file: "hello.txt" },
    ],
    doneWhen: [
      { text: "hello.txt says hello", proof: "terminal" },
      { text: "The branch has the commit", proof: "terminal" },
    ],
    // "[risky]" rates it high, so a person approves and merges it instead of the factory.
    risk: prompt.includes("[risky]") ? { level: "high", reasons: ["It touches the release path."], areas: ["release"] } : { level: "low", reasons: ["One new text file."], areas: [] },
    footprint: { files: 1, lines: 1 },
    // "[rename: X]": the plan suggests X as the task's title.
    ...(rename ? { title: rename[1] } : {}),
    // "[cross-repo]": the goal's next repo gets the part that uses this one, as its own task.
    otherRepos: prompt.includes("[cross-repo]")
      ? [...prompt.matchAll(/^- ([\w.-]+\/[\w.-]+)$/gm)].slice(0, 1).map(([, repo]) => ({ repo, title: `Use ${data.task.id}'s greeting`, brief: `Show the greeting ${data.task.id} adds. Add hello.txt with a greeting.` }))
      : [],
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
  if (prompt.includes("## It didn't merge")) return mergeFix();
  const fixing = /asked for changes|## Change requests to apply/.test(prompt);
  if (prompt.includes("[hand]") && !fixing) {
    await call("raise_hand", {
      reason: "needsInput",
      summary: "The greeting could go in a file or the README; the plan doesn't say.",
      options: [
        { title: "A new file", detail: "hello.txt, as planned.", recommended: true },
        { title: "The README", detail: "Append it to README.md." },
      ],
    });
    await nextLine();
  }
  // Change requests typed in while it worked ("Change request C2 from ann: …"), as steering does.
  const steered = typed.splice(0).map((l) => l.match(/^Change request (C\d+) from [^:]+: (.*)$/)).filter(Boolean);
  for (const [, id, text] of steered) say(`steered (${id}): ${text}`);
  // Change requests in the prompt (asked for before this session started), applied the same way.
  const requested = [...prompt.matchAll(/^- \((C\d+)\) [^:]+: (.*)$/gm)];
  await call("progress", { step: 1, status: "active", note: fixing ? "Fixing the review's findings" : "Writing hello.txt" });
  // Edits what's there, like an agent would: earlier rounds' lines stay.
  const greeting = `hello from ${data.task.id}`;
  const before = existsSync("hello.txt") ? readFileSync("hello.txt", "utf8").split("\n").filter(Boolean) : [];
  const lines = before[0] === greeting ? before : [greeting];
  for (const line of [fixing && "(with a trailing newline, as review asked)", ...[...requested, ...steered].map(([, , text]) => text)]) {
    if (line && !lines.includes(line)) lines.push(line);
  }
  writeFileSync("hello.txt", lines.join("\n") + "\n");
  await call("progress", { step: 1, status: "done" });
  await call("progress", { step: 2, status: "active", note: "Committing" });
  git("add", "hello.txt");
  if (git("status", "--porcelain")) git("-c", "user.name=Scripted", "-c", "user.email=scripted@maple.invalid", "commit", "-qm", fixing ? "Address review" : "Add hello.txt");
  await call("progress", { step: 2, status: "done" });
  const applied = [...requested, ...steered].map(([, id]) => id);
  if (applied.length) await call("progress", { applied });
  if (prompt.includes("[attest]")) {
    say("waiting for both items to be attested");
    while (!(await call("get_task")).data.task.doneWhen.every((d) => d.evidence?.attested)) await new Promise((r) => setTimeout(r, 500));
  }
  await call("prove", { item: 1, kind: "terminal", summary: "hello.txt has the greeting", command: "cat hello.txt", output: git("show", "HEAD:hello.txt").split("\n") });
  await call("prove", { item: 2, kind: "terminal", summary: "The commit is on the branch", command: "git log --oneline -3", output: git("log", "--oneline", "-3").split("\n") });
  const done = await call("finish", { summary: fixing ? "Addressed the review's finding." : "Added hello.txt with the task's greeting." });
  say(done.summary);
}

// "## It didn't merge": bring the branch up to date with its base, keeping both sides of any
// conflicting file's lines, and push. The merge commit names the change request it applies.
async function mergeFix() {
  const base = prompt.match(/bring it up to date with origin\/(\S+) and/)[1];
  const [, id, text] = prompt.match(/^- \((C\d+)\) [^:]+: (The branch doesn't merge.*)$/m);
  say(`merging origin/${base} (${id})`);
  await call("progress", { note: `Merging origin/${base} for ${id}` });
  git("fetch", "--quiet", "origin", base);
  const as = ["-c", "user.name=Scripted", "-c", "user.email=scripted@maple.invalid"];
  try {
    git(...as, "merge", "--no-edit", "--quiet", `origin/${base}`);
  } catch {
    for (const file of git("diff", "--name-only", "--diff-filter=U").split("\n").filter(Boolean)) {
      const side = (n) => { try { return git("show", `:${n}:${file}`).split("\n"); } catch { return []; } };
      const ours = side(2);
      writeFileSync(file, [...ours, ...side(3).filter((l) => !ours.includes(l))].join("\n") + "\n");
      git("add", file);
      say(`resolved ${file}`);
    }
    git(...as, "commit", "--quiet", "-m", `Merge origin/${base} (${id}: ${text})`);
  }
  await call("progress", { applied: [id] });
  await call("prove", { item: 1, kind: "terminal", summary: "hello.txt keeps the greeting after the merge", command: "cat hello.txt", output: git("show", "HEAD:hello.txt").split("\n") });
  const done = await call("finish", { summary: `Merged origin/${base} into the branch and resolved the conflicts.` });
  say(done.summary);
}

async function reviewer() {
  const open = [...prompt.matchAll(/- \((R\d+\.\d+)\)/g)].map((m) => m[1]);
  // A branch that already took review's fix (say, one sent back because it didn't merge) passes.
  const first = !/Open findings from earlier rounds/.test(prompt) && !(existsSync("hello.txt") && readFileSync("hello.txt", "utf8").includes("as review asked"));
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

// "[slow]" in a brief keeps each session busy for a while first, so it can be watched live.
// "[slow-build]" only slows the builder, after it has started writing (uncommitted), so a hand-off
// has work to carry.
const slowBuild = prompt.includes("[slow-build]") && /You are the builder/.test(prompt) && !/moved here from/.test(prompt);
if (slowBuild) writeFileSync("wip.txt", "started on the first machine\n");
// "[slow-review]" only slows the review agent.
const slowReview = prompt.includes("[slow-review]") && /You are the review agent/.test(prompt);
if (prompt.includes("[slow]") || slowBuild || slowReview) {
  for (let i = 1; i <= 45; i++) {
    say(`thinking (${i})…`);
    await new Promise((r) => setTimeout(r, 2000));
  }
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
