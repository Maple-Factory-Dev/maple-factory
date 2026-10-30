// The `maple` MCP tools each factory session gets, by role, and the ones every other session on a
// member's machine gets (PERSONAL_TOOLS). The runner asks for the list per session and forwards
// calls here; the engine runs them (engine.ts `tool`).

import type { Role } from "../wire.ts";

type Schema = Record<string, unknown>;

interface Tool {
  name: string;
  description: string;
  inputSchema: Schema;
  roles: Role[];
}

const str = (description: string) => ({ type: "string", description });
const int = (description: string) => ({ type: "integer", minimum: 0, description });
const list = (items: Schema, description: string) => ({ type: "array", items, description });
const obj = (properties: Record<string, Schema>, required: string[] = []) => ({ type: "object", properties, required, additionalProperties: false });
const oneOf = (values: string[], description: string) => ({ type: "string", enum: values, description });

const handOptions = list(
  obj({ title: str("What would happen."), detail: str("Its trade-off."), recommended: { type: "boolean" } }, ["title", "detail"]),
  "Two or three ways forward a person can pick from.",
);

const TOOLS: Tool[] = [
  {
    name: "get_task",
    description: "The task you're working on: brief, plan, Done when items and their evidence, comments, change requests and review findings.",
    inputSchema: obj({}),
    roles: ["planner", "builder", "reviewer"],
  },
  {
    name: "submit_plan",
    description: "Submit the plan for approval. Call once, then end your turn.",
    inputSchema: obj(
      {
        summary: str("The approach in two or three sentences."),
        title: str("A clearer title for the task, only if its current one is vague or misleading; it takes this name once the plan is approved."),
        steps: list(obj({ text: str("What this step does."), file: str("The main file it touches.") }, ["text", "file"]), "3–8 steps in order."),
        doneWhen: list(
          obj({ text: str("A check that proves the change works."), proof: oneOf(["tests", "terminal", "screenshot", "video"], "What evidence the builder produces.") }, ["text", "proof"]),
          "2–5 checks.",
        ),
        risk: obj(
          {
            level: oneOf(["low", "medium", "high"], "High for auth, payments, migrations, public APIs."),
            reasons: list(str(""), "Why."),
            areas: list(str(""), "Sensitive areas it touches, e.g. auth, billing."),
          },
          ["level", "reasons"],
        ),
        footprint: obj({ files: int("Files changed."), lines: int("Lines changed.") }, ["files", "lines"]),
        mockups: list(
          obj(
            {
              title: str("e.g. \"Locked out\"."),
              kind: oneOf(["screen", "terminal"], "A screen (html) or terminal output (lines)."),
              url: str("For a screen: the page's path, shown in the browser frame."),
              html: str("For a screen: a small self-contained HTML page (inline CSS, no scripts)."),
              lines: list(
                obj({ text: str(""), style: oneOf(["command", "output", "highlight", "dim", "error"], ""), callout: int("Callout number, on lines that change.") }, ["text", "style"]),
                "For a terminal mockup.",
              ),
              notes: list(str(""), "Numbered callouts, in order: what changes and why."),
            },
            ["title", "kind", "notes"],
          ),
          "Pictures of the change: required for UI work.",
        ),
        otherRepos: list(
          obj(
            {
              repo: str("One of the goal's other repos (owner/name)."),
              title: str("The task's title there."),
              brief: str("What that repo needs, for its own planner: what this task changes that it builds on."),
            },
            ["repo", "title", "brief"],
          ),
          "Parts of the work that belong in the goal's other repos; each becomes a task there once this plan is approved.",
        ),
      },
      ["summary", "steps", "doneWhen", "risk", "footprint"],
    ),
    roles: ["planner"],
  },
  {
    name: "ask",
    description: "Ask a person a question you can't answer from the code or brief. End your turn after; the answer is typed into this session.",
    inputSchema: obj({ question: str("One question."), options: list(str(""), "Likely answers, if there are some.") }, ["question"]),
    roles: ["planner", "builder"],
  },
  {
    name: "raise_hand",
    description: "Stop and ask a person for help: you can't produce a proof, the fix outgrows the plan, or you need input the plan doesn't have.",
    inputSchema: obj(
      {
        reason: oneOf(["proofBurden", "needsInput", "overBudget"], "Why you're stuck."),
        summary: str("What happened and what you tried, in a few sentences."),
        options: handOptions,
      },
      ["reason", "summary", "options"],
    ),
    roles: ["planner", "builder"],
  },
  {
    name: "progress",
    description: "Report progress: a plan step started or finished, what you're doing, or change requests you applied.",
    inputSchema: obj({
      step: int("The plan step, from 1."),
      status: oneOf(["active", "done"], "Started or finished."),
      note: str("What you're doing right now, one line."),
      applied: list(str(""), "Ids of change requests you've applied."),
    }),
    roles: ["builder"],
  },
  {
    name: "prove",
    description: "Attach evidence for a Done when item.",
    inputSchema: obj(
      {
        item: int("The Done when item, from 1."),
        kind: oneOf(["tests", "terminal", "screenshot", "video"], "Must match the item's proof kind."),
        summary: str("What the evidence shows, one line."),
        command: str("The command you ran (terminal/tests)."),
        output: list(str(""), "Its output's lines (the last 60 are kept)."),
        passed: int("Tests passed."),
        failed: int("Tests failed."),
        file: str("For a screenshot or video: the full path of a PNG, JPEG, WebP, MP4, MOV or WebM (video at most 25 MB, others 5 MB) saved under ~/.cache/maple-proof/<this task's branch>/, never in the worktree. The runner uploads it."),
      },
      ["item", "kind", "summary"],
    ),
    roles: ["builder"],
  },
  {
    name: "finish",
    description: "Every step is done and every item proven: the factory commits, pushes and starts the review. End your turn after.",
    inputSchema: obj({ summary: str("What changed, for the review and the pull request.") }, ["summary"]),
    roles: ["builder"],
  },
  {
    name: "submit_review",
    description: "Submit this review round. Call once, then end your turn.",
    inputSchema: obj(
      {
        verdict: oneOf(["passed", "changesRequested"], "passed only with no blocker or major findings."),
        summary: str("The review in two or three sentences."),
        ask: list(obj({ text: str("A part of the brief."), verdict: oneOf(["met", "partial", "missed"], ""), note: str("") }, ["text", "verdict"]), "Did it do the ask?"),
        proofs: list(obj({ text: str("A Done when item."), verdict: oneOf(["met", "partial", "missed"], ""), note: str("") }, ["text", "verdict"]), "Is each proof real?"),
        findings: list(
          obj(
            {
              kind: oneOf(["scope", "proof", "code", "risk"], ""),
              severity: oneOf(["blocker", "major", "minor"], ""),
              text: str("What's wrong and what to do."),
              file: str("Where, e.g. src/auth.ts:42."),
            },
            ["kind", "severity", "text"],
          ),
          "New problems found this round.",
        ),
        fixed: list(str(""), "Ids of earlier findings this round resolves."),
      },
      ["verdict", "summary", "ask", "proofs", "findings"],
    ),
    roles: ["reviewer"],
  },
];

const scriptsSchema = obj({
  create: str("Makes the worktree in place of `git worktree add`; it must leave a git worktree on $MAPLE_BRANCH at $MAPLE_WORKTREE. Usually left out."),
  preflight: str("Machine-level setup (runtimes, brew, services), run in the new worktree before setup the first time a machine uses the repo, and again when the command or a watched file changes."),
  preflightWatch: str("Repo-relative files, one per line, that re-run preflight when they change (at most 20). Left out: .ruby-version, .tool-versions, .node-version, .nvmrc, .python-version, Brewfile and mise.toml."),
  setup: str("Runs once the worktree exists, before the agent starts: install dependencies, copy .env files, and so on."),
  teardown: str("Runs before the worktree is removed when a finished task is cleaned up."),
  archive: str("Runs in place of the runner's own removal at cleanup. Usually left out."),
  timeoutSecs: { type: "integer", minimum: 1, maximum: 3600, description: "How long each may run (default 600)." },
});
const promptsSchema = obj({
  planner: str("Markdown added to the planner's prompt for this repo's tasks."),
  builder: str("Markdown added to the builder's prompt: how to run, test and prove changes here."),
  reviewer: str("Markdown added to the reviewer's prompt: what to check."),
});

/** The tools of a session that isn't working on a factory task: your own Claude Code or Codex on a member's machine. */
const PERSONAL_TOOLS: Omit<Tool, "roles">[] = [
  {
    name: "get_repo_setup",
    description: "One of the factory's repos' setup: its worktree scripts (run by the runner with /bin/sh -c in the repo's main checkout), its prompt additions per role (added after the org's and before a goal's), the MAPLE_* variables the scripts get, and who changed them last.",
    inputSchema: obj({ repo: str("The repo, GitHub owner/name.") }, ["repo"]),
  },
  {
    name: "save_repo_setup",
    description: "Save a repo's worktree scripts and prompt additions, straight away (admins' machines only; audited). Only the fields you pass change: an empty string clears one, a field left out keeps what's stored. Call get_repo_setup first.",
    inputSchema: obj({ repo: str("The repo, GitHub owner/name."), scripts: scriptsSchema, prompts: promptsSchema }, ["repo"]),
  },
];

export function personalTools() {
  return PERSONAL_TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema }));
}

export function isPersonalTool(tool: string) {
  return PERSONAL_TOOLS.some((t) => t.name === tool);
}

export function toolsFor(role: Role) {
  return TOOLS.filter((t) => t.roles.includes(role)).map(({ name, description, inputSchema }) => ({ name, description, inputSchema }));
}

export function allowed(role: Role, tool: string) {
  return TOOLS.some((t) => t.name === tool && t.roles.includes(role));
}
