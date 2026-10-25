// Maple Factory on the web: review on the go. The same live feed as the apps (/client/connect, signed
// in by the session cookie): the inbox, and a task's plan, mockups, diff, review and proofs, with the
// decisions a person makes on them. Nothing here touches terminals or machines.
//
// Every string from the factory goes in with textContent; agents' screen mockups render in an iframe
// with an empty sandbox (no scripts, no same-origin).

const state = { me: null, org: "", members: [], goals: [], tasks: new Map(), live: false, diffs: new Map() };
let socket = null;
let retry = 1000;

// ---- DOM ----

function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs ?? {})) {
    if (v == null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat(Infinity)) if (c != null && c !== false) el.append(c instanceof Node ? c : String(c));
  return el;
}
const $ = (id) => document.getElementById(id);

const STATES = ["drafting", "planning", "awaitingApproval", "building", "reviewing", "merged"];
const STATE_TITLE = { drafting: "Drafting", planning: "Planning", awaitingApproval: "Awaiting approval", building: "Building", reviewing: "Reviewing", merged: "Merged", cancelled: "Cancelled" };
const name = (login) => {
  if (["planner", "builder", "reviewer", "factory"].includes(login)) return login[0].toUpperCase() + login.slice(1);
  if (login === state.me?.login) return "You";
  return state.members.find((m) => m.login === login)?.name || login;
};
const goalOf = (t) => state.goals.find((g) => g.id === t.goal);
function ago(ms) {
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}
function toast(text) {
  const t = $("toast");
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (t.hidden = true), 3500);
}

// ---- the feed ----

function connect() {
  const url = `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/client/connect`;
  socket = new WebSocket(url);
  let opened = false;
  socket.onopen = () => {
    opened = true;
    retry = 1000;
    socket.send(JSON.stringify({ type: "subscribe" }));
    view();
  };
  socket.onmessage = (e) => receive(JSON.parse(e.data));
  socket.onclose = async () => {
    state.live = false;
    status();
    // Never connected: maybe not signed in.
    if (!opened && (await fetch("/api/me").then((r) => r.status === 401).catch(() => false))) return signIn();
    setTimeout(connect, retry);
    retry = Math.min(retry * 2, 15000);
  };
}

function send(msg) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(msg));
  else toast("Not connected; try again in a moment.");
}

function receive(m) {
  switch (m.type) {
    case "snapshot":
      Object.assign(state, { me: m.me, org: m.org, members: m.members, goals: m.goals, live: true });
      state.tasks = new Map(m.tasks.map((t) => [t.id, t]));
      $("org").textContent = m.org || "Maple Factory";
      status();
      break;
    case "task.updated": state.tasks.set(m.task.id, m.task); break;
    case "task.removed": state.tasks.delete(m.id); break;
    case "goal.updated": state.goals = [...state.goals.filter((g) => g.id !== m.goal.id), m.goal]; break;
    case "toast": toast(m.text); break;
    case "error": toast(m.message); break;
    default: return;
  }
  render();
}

function status() {
  const s = $("status");
  s.textContent = state.live ? "Live" : "Reconnecting…";
  s.className = `status${state.live ? " live" : ""}`;
}

function signIn() {
  $("main").replaceChildren(h("div", { class: "signin" },
    h("h1", {}, "Sign in"),
    h("p", { class: "muted" }, "Members of the factory's GitHub organization review and approve work here."),
    h("p", {}, h("a", { class: "btn primary", href: `/auth/login?next=${encodeURIComponent(location.pathname + location.hash)}` }, "Sign in with GitHub"))));
}

// ---- what needs you ----

function needsYou(t) {
  const me = state.me?.login;
  if (!me) return null;
  if (t.hand && t.hand.assignee === me) return { kind: "hand", text: t.hand.summary };
  if (t.question && t.owner === me) return { kind: "question", text: t.question.text };
  if (t.state === "awaitingApproval" && !t.approvals.includes(me)) return { kind: "plan", text: `Plan v${t.planVersion} is ready for your approval` };
  if (t.state === "reviewing" && t.autoReview?.rounds.at(-1)?.verdict === "passed" && t.reviews.length < t.reviewsNeeded && !t.reviews.includes(me)) {
    return { kind: "review", text: "Passed automatic review; ready for yours" };
  }
  if (t.pr?.checks?.some((c) => c.status === "failed") && t.owner === me && t.state === "reviewing") return { kind: "ci", text: "CI is failing" };
  return null;
}
const KINDS = { hand: ["Needs a hand", "cancelled"], question: ["Questions", "awaitingApproval"], plan: ["Plans awaiting approval", "awaitingApproval"], review: ["Ready for review", "reviewing"], ci: ["Failing CI", "cancelled"] };

// ---- views ----

function route() {
  const hash = location.hash.replace(/^#/, "") || "/";
  const task = hash.match(/^\/t\/([A-Z][A-Z0-9]*-\d+)$/);
  return task ? { name: "task", id: task[1] } : hash === "/tasks" ? { name: "tasks" } : { name: "inbox" };
}

function render() {
  if (!state.me) return;
  const r = route();
  for (const a of document.querySelectorAll("[data-nav]")) a.classList.toggle("on", a.dataset.nav === r.name);
  const waiting = [...state.tasks.values()].filter(needsYou).length;
  $("inbox-count").textContent = waiting || "";
  document.title = `${waiting ? `(${waiting}) ` : ""}Maple Factory`;
  // Keep what someone's typing: re-render a task page only around its compose boxes.
  const focused = document.activeElement?.closest?.("[data-keep]");
  if (focused && r.name === "task") return renderTask(r.id, true);
  $("main").replaceChildren(r.name === "task" ? taskView(r.id) : r.name === "tasks" ? tasksView() : inboxView());
}
const view = render;

function row(t, sub) {
  const goal = goalOf(t);
  return h("a", { class: "item", href: `#/t/${t.id}` },
    h("span", { class: `dot bg-${t.state}` }),
    h("div", {},
      h("div", { class: "title" }, t.title),
      h("div", { class: "sub" }, h("span", { class: "mono" }, t.id), goal ? ` · ${goal.name}` : "", ` · ${sub}`)));
}

function inboxView() {
  const groups = new Map();
  for (const t of state.tasks.values()) {
    const n = needsYou(t);
    if (n) groups.set(n.kind, [...(groups.get(n.kind) ?? []), [t, n]]);
  }
  const total = [...groups.values()].reduce((a, g) => a + g.length, 0);
  return h("div", {},
    h("h1", {}, "Inbox"),
    h("p", { class: "muted" }, total ? `${total} thing${total === 1 ? "" : "s"} waiting on you.` : "Nothing's waiting on you."),
    Object.keys(KINDS).filter((k) => groups.has(k)).map((k) => [
      h("h2", {}, `${KINDS[k][0]} · ${groups.get(k).length}`),
      h("div", { class: "list" }, groups.get(k).map(([t, n]) => row(t, n.text))),
    ]),
    !total && h("div", { class: "card empty" }, "When a plan needs your approval, an agent asks something, or a change is ready for your review, it shows up here."));
}

function tasksView() {
  const active = [...state.tasks.values()].filter((t) => t.state !== "merged" && t.state !== "cancelled").sort((a, b) => b.updatedAt - a.updatedAt);
  const done = [...state.tasks.values()].filter((t) => t.state === "merged").sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 10);
  return h("div", {},
    h("h1", {}, "Tasks"),
    h("h2", {}, `In flight · ${active.length}`),
    active.length ? h("div", { class: "list" }, active.map((t) => row(t, t.waiting || STATE_TITLE[t.state]))) : h("div", { class: "card empty" }, "Nothing in flight."),
    done.length > 0 && [h("h2", {}, "Recently merged"), h("div", { class: "list" }, done.map((t) => row(t, `merged ${ago(t.updatedAt)}`)))]);
}

// ---- a task ----

const taskTabs = new Map(); // id → "overview" | "diff"

function renderTask(id, keepCompose) {
  const main = $("main");
  const next = taskView(id);
  if (keepCompose) {
    // Swap everything but the boxes being typed in.
    const kept = new Map([...main.querySelectorAll("[data-keep]")].map((el) => [el.dataset.keep, el]));
    for (const slot of next.querySelectorAll("[data-keep]")) {
      const old = kept.get(slot.dataset.keep);
      if (old) slot.replaceWith(old);
    }
  }
  main.replaceChildren(next);
}

function taskView(id) {
  const t = state.tasks.get(id);
  if (!t) return h("div", { class: "card empty" }, state.live ? `There's no task ${id}.` : "Loading…");
  const goal = goalOf(t);
  const tab = taskTabs.get(id) ?? "overview";
  const reached = t.state === "cancelled" ? -1 : STATES.indexOf(t.state);
  return h("div", {},
    h("div", { class: "row muted" }, h("a", { href: "#/" }, "← Inbox"), h("span", { class: "spacer" }), h("span", { class: "mono" }, t.id)),
    h("h1", {}, t.title),
    h("div", { class: "row" },
      h("span", { class: `pill s-${t.state}` }, STATE_TITLE[t.state]),
      h("span", { class: "muted" }, `${name(t.owner)} · ${goal?.name ?? ""}${(goal?.repos?.length ?? 0) > 1 ? ` · ${t.repo ?? goal.repo}` : ""} · updated ${ago(t.updatedAt)}`)),
    (t.after ?? []).length > 0 && h("div", { class: "muted", style: "font-size:13px;margin-top:4px" }, "Builds on ",
      t.after.map((id, i) => [i ? ", " : "", h("a", { href: `#/t/${id}` }, id)])),
    h("div", { class: "stepper" }, STATES.map((s, i) => h("span", { class: i <= reached ? `bg-${STATES[Math.min(i, reached)]}` : "" }))),
    t.waiting && h("p", { class: "muted" }, t.waiting),
    t.liveLog && !t.waiting && t.worker && h("p", { class: "muted" }, `${name(t.worker.role)}: ${t.liveLog}`),
    t.hand && handCard(t),
    t.question && !t.hand && questionCard(t),
    decisions(t),
    h("div", { class: "tabs", style: "margin-top:22px" },
      h("button", { class: `tab${tab === "overview" ? " on" : ""}`, onclick: () => { taskTabs.set(id, "overview"); render(); } }, "Overview"),
      t.diff && h("button", { class: `tab${tab === "diff" ? " on" : ""}`, onclick: () => { taskTabs.set(id, "diff"); render(); } }, `Diff +${t.diff.added} −${t.diff.removed}`)),
    tab === "diff" ? diffView(t) : overview(t));
}

function handCard(t) {
  const mine = t.hand.assignee === state.me?.login;
  return h("div", { class: "callout hand" },
    h("b", {}, "The agent needs a hand"),
    h("p", { style: "margin:6px 0 0" }, t.hand.summary),
    mine && h("div", { class: "options" }, t.hand.options.map((o) =>
      h("button", { class: `option${o.recommended ? " recommended" : ""}`, onclick: () => send({ type: "task.resolveHand", id: t.id, option: o.title, note: "" }) },
        h("b", {}, o.title + (o.recommended ? " · recommended" : "")), h("span", { class: "muted" }, o.detail)))),
    mine && compose(t, "hand", "Or say what to do…", "Send", (text) => send({ type: "task.resolveHand", id: t.id, option: null, note: text })),
    !mine && h("p", { class: "muted" }, `Waiting on ${name(t.hand.assignee)}.`));
}

function questionCard(t) {
  const mine = t.owner === state.me?.login;
  return h("div", { class: "callout question" },
    h("b", {}, `${name(t.question.role)} asks`),
    h("p", { style: "margin:6px 0 0" }, t.question.text),
    mine && t.question.options.length > 0 && h("div", { class: "options" }, t.question.options.map((o) =>
      h("button", { class: "option", onclick: () => send({ type: "task.answer", id: t.id, text: o }) }, h("b", {}, o)))),
    mine && compose(t, "answer", "Answer…", "Answer", (text) => send({ type: "task.answer", id: t.id, text })),
    !mine && h("p", { class: "muted" }, `${name(t.owner)} answers this.`));
}

/** The decision buttons for where the task is. */
function decisions(t) {
  const me = state.me?.login;
  const buttons = [];
  if (t.state === "awaitingApproval") {
    buttons.push(h("button", { class: "btn go", disabled: t.approvals.includes(me), onclick: () => send({ type: "task.approvePlan", id: t.id }) },
      t.approvals.includes(me) ? "You approved it" : "Approve plan"));
    buttons.push(h("span", { class: "muted", style: "align-self:center;font-size:13px" }, `${t.approvals.length} of ${t.approvalsNeeded} approvals`));
  }
  if (t.state === "reviewing") {
    const passed = t.autoReview?.rounds.at(-1)?.verdict === "passed";
    const failing = t.pr?.checks?.some((c) => c.status === "failed");
    const pending = t.pr?.checks?.some((c) => c.status !== "passed" && c.status !== "failed");
    if (passed && t.reviews.length < t.reviewsNeeded) {
      buttons.push(h("button", { class: "btn go", disabled: t.reviews.includes(me), onclick: () => send({ type: "task.approveChanges", id: t.id }) },
        t.reviews.includes(me) ? "You approved the changes" : "Approve changes"));
      buttons.push(h("span", { class: "muted", style: "align-self:center;font-size:13px" }, `${t.reviews.length} of ${t.reviewsNeeded} approvals`));
    }
    if (passed && t.reviews.length >= t.reviewsNeeded) {
      buttons.push(h("button", { class: "btn go", disabled: failing || pending, onclick: () => send({ type: "task.merge", id: t.id }) },
        failing ? "CI is failing" : pending ? "Waiting for CI" : "Merge"));
    }
    if (failing) buttons.push(h("button", { class: "btn", onclick: () => send({ type: "task.rerunChecks", id: t.id }) }, "Re-run failed"));
    if (!passed) buttons.push(h("span", { class: "muted", style: "align-self:center;font-size:13px" }, "The review agent is still on it."));
  }
  const steerable = ["planning", "awaitingApproval", "building", "reviewing"].includes(t.state);
  const [placeholder, label] = {
    awaitingApproval: ["Ask for a change to the plan…", "Request change"],
    reviewing: ["What should change before it merges? The builder picks it up.", "Request changes"],
  }[t.state] ?? ["Steer it: what should change?", "Request change"];
  return h("div", {},
    buttons.length > 0 && h("div", { class: "actions" }, buttons),
    steerable && compose(t, "steer", placeholder, label, (text) => send({ type: "task.steer", id: t.id, text })));
}

function compose(t, key, placeholder, label, submit) {
  const box = h("textarea", { placeholder, rows: 2 });
  const go = () => {
    const text = box.value.trim();
    if (!text) return;
    submit(text);
    box.value = "";
    box.blur();
  };
  box.addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) go(); });
  return h("div", { class: "compose", "data-keep": `${t.id}:${key}` }, box, h("div", {}, h("button", { class: "btn small", onclick: go }, label)));
}

function overview(t) {
  return h("div", {},
    t.brief && [h("h2", {}, "Brief"), h("div", { class: "card", style: "white-space:pre-wrap" }, t.brief)],
    t.autoReview && t.autoReview.rounds.length > 0 && review(t),
    t.pr && pull(t),
    t.mockups.length > 0 && [h("h2", {}, "Mockups"), t.mockups.map(mockup)],
    t.plan.length > 0 && [h("h2", {}, `Plan · v${t.planVersion}`), h("div", { class: "card" },
      h("ol", { class: "steps" }, t.plan.map((s) => h("li", { class: s.progress === "done" ? "done" : s.progress === "active" ? "active" : "" },
        h("div", {}, s.text, s.file && h("div", { class: "mono muted" }, s.file))))))],
    (t.followUps ?? []).length > 0 && [h("h2", {}, "In the goal's other repos"), h("div", { class: "card" },
      t.followUps.map((f) => h("div", { class: "check" }, h("div", {},
        h("b", {}, f.title), h("div", { class: "mono muted" }, f.repo),
        f.task ? h("a", { href: `#/t/${f.task}` }, f.task) : h("span", { class: "faint" }, "A task of its own once the plan is approved")))))],
    t.doneWhen.length > 0 && [h("h2", {}, "Done when"), h("div", { class: "card" }, t.doneWhen.map(doneItem))],
    timeline(t));
}

function review(t) {
  const r = t.autoReview;
  const last = r.rounds.at(-1);
  const verdict = { passed: ["Passed", "ok"], changesRequested: ["Asked for changes", "wait"], escalated: ["Handed to a person", "bad"], inProgress: ["Reviewing…", "muted"] }[last.verdict];
  const open = r.findings.filter((f) => f.status === "open");
  return [h("h2", {}, "Automated review"), h("div", { class: "card" },
    h("div", { class: "row" }, h("b", {}, `Round ${last.number} of ${r.maxRounds}`), h("span", { class: verdict[1] }, verdict[0])),
    r.summary && h("p", { style: "margin:8px 0" }, r.summary),
    [...r.ask.map((c) => ["Asked", c]), ...r.proofs.map((c) => ["Proof", c])].map(([kind, c]) => h("div", { class: "check" },
      h("span", { class: `mark ${c.verdict === "met" ? "ok" : c.verdict === "notMet" ? "bad" : "wait"}` }, c.verdict === "met" ? "✓" : c.verdict === "notMet" ? "✕" : "•"),
      h("div", {}, h("span", { class: "muted" }, `${kind}: `), c.text, c.note && h("div", { class: "muted" }, c.note)))),
    open.length > 0 && [h("h2", { style: "margin-top:14px" }, `Open findings · ${open.length}`), open.map((f) => h("div", { class: "check" },
      h("span", { class: "mark bad" }, "!"), h("div", {}, f.text, f.file && h("div", { class: "mono muted" }, f.file))))])];
}

function pull(t) {
  const pr = t.pr;
  return [h("h2", {}, "Pull request"), h("div", { class: "card" },
    h("div", { class: "row" },
      pr.url ? h("a", { href: pr.url, target: "_blank", rel: "noopener" }, `#${pr.number} ↗`) : h("b", {}, `#${pr.number}`),
      h("span", { class: "pill" }, t.state === "cancelled" && (pr.state === "open" || pr.state === "draft") ? "closed" : pr.state),
      h("span", { class: "mono muted" }, `${pr.branch} → ${pr.base}`)),
    pr.checks.length === 0
      ? h("p", { class: "muted", style: "margin:8px 0 0" }, pr.url ? "No CI checks reported." : "No CI: a local repo's change is checked by its proofs and review.")
      : pr.checks.map((c) => h("div", { class: "check" },
        h("span", { class: `mark ${c.status === "passed" ? "ok" : c.status === "failed" ? "bad" : "wait"}` }, c.status === "passed" ? "✓" : c.status === "failed" ? "✕" : "•"),
        h("div", { class: "row", style: "flex:1" }, c.name, h("span", { class: "spacer" }), h("span", { class: "muted" }, c.duration ?? c.status)))))];
}

function mockup(m) {
  const body = m.kind === "terminal"
    ? h("div", { class: "terminal" }, m.lines.map((l) => h("div", { class: l.style }, l.text || " ", l.callout && h("span", { class: "callout-n" }, l.callout))))
    : h("div", { class: "browser" }, h("div", { class: "url" }, m.url ?? m.title),
      h("iframe", { class: "mockup-frame", sandbox: "", srcdoc: m.html ?? "", title: m.title, loading: "lazy" }));
  return h("div", { style: "margin-bottom:14px" },
    h("div", { class: "row", style: "margin-bottom:6px" }, h("b", {}, m.title), h("span", { class: "muted" }, m.status === "approved" ? "· approved" : m.status === "changesRequested" ? "· changes asked" : "")),
    body,
    m.notes.length > 0 && h("ol", { class: "muted", style: "margin:8px 0 0;padding-left:20px;font-size:14px" }, m.notes.map((n) => h("li", {}, n))));
}

function doneItem(d) {
  const ok = d.status === "proven";
  return h("div", { class: "check" },
    h("span", { class: `mark ${ok ? "ok" : d.status === "failed" ? "bad" : "wait"}` }, ok ? "✓" : d.status === "failed" ? "✕" : "○"),
    h("div", { style: "flex:1;min-width:0" }, d.text,
      d.evidence && h("div", { class: "muted", style: "font-size:13.5px" }, d.evidence.summary),
      d.evidence?.output?.length > 0 && h("pre", { class: "out" }, [d.evidence.command && `$ ${d.evidence.command}`, ...d.evidence.output].filter(Boolean).join("\n"))));
}

function timeline(t) {
  const items = [
    ...t.events.map((e) => ({ at: e.at, el: h("div", { class: "event" }, h("b", {}, name(e.who)), " ", e.text, h("span", { class: "when" }, ago(e.at))) })),
    ...t.comments.map((c) => ({ at: c.at, el: h("div", { class: "comment" }, h("div", { class: "row" }, h("b", {}, name(c.author)), c.via && h("span", { class: "muted" }, `via ${c.via}`), h("span", { class: "when faint" }, ago(c.at))), h("div", { style: "white-space:pre-wrap" }, c.text)) })),
    ...t.changes.map((c) => ({ at: c.at, el: h("div", { class: "comment" }, h("div", { class: "row" }, h("b", {}, name(c.author)), h("span", { class: "muted" }, `asked for a change · ${c.status}`), h("span", { class: "when faint" }, ago(c.at))), h("div", {}, c.text)) })),
  ].sort((a, b) => b.at - a.at);
  return [h("h2", {}, "Timeline"),
    compose(t, "comment", "Comment…", "Comment", (text) => send({ type: "task.comment", id: t.id, text })),
    h("div", { class: "timeline", style: "margin-top:14px" }, items.slice(0, 60).map((i) => i.el))];
}

// ---- the diff ----

function diffView(t) {
  const key = `${t.pr?.head ?? ""}+${t.diff?.added}-${t.diff?.removed}`;
  const cached = state.diffs.get(t.id);
  if (!cached || cached.key !== key) {
    state.diffs.set(t.id, { key, files: null });
    fetch(`/api/tasks/${t.id}/diff`).then((r) => (r.ok ? r.text() : "")).then((text) => {
      state.diffs.set(t.id, { key, files: parseDiff(text) });
      render();
    });
  }
  const files = state.diffs.get(t.id).files;
  if (!files) return h("div", { class: "card empty" }, "Loading the diff…");
  if (!files.length) return h("div", { class: "card empty" }, "No diff yet.");
  return h("div", { style: "margin-top:12px" }, files.map((f) => h("div", { class: "diff" },
    h("div", { class: "file" }, h("span", {}, f.path), h("span", { class: "spacer" }), h("span", { class: "ok" }, `+${f.added}`), h("span", { class: "bad" }, `−${f.removed}`)),
    h("div", { class: "scroll" }, h("table", {}, f.lines.map((l) => h("tr", { class: l.kind },
      h("td", { class: "n" }, l.old ?? ""), h("td", { class: "n" }, l.new ?? ""), h("td", { class: "c" }, l.text))))))));
}

function parseDiff(text) {
  const files = [];
  let f = null;
  let o = 0;
  let n = 0;
  for (const line of text.split("\n")) {
    if (line.startsWith("diff --git ")) {
      f = { path: line.replace(/^diff --git a\/(.+?) b\/.*$/, "$1"), added: 0, removed: 0, lines: [] };
      files.push(f);
    } else if (!f || line.startsWith("index ") || line.startsWith("--- ") || line.startsWith("+++ ") || line.startsWith("new file") || line.startsWith("deleted file")) {
      if (f && line.startsWith("+++ b/")) f.path = line.slice(6);
    } else if (line.startsWith("@@")) {
      const m = line.match(/@@ -(\d+)(?:,\d+)? \+(\d+)/);
      o = Number(m?.[1] ?? 0);
      n = Number(m?.[2] ?? 0);
      f.lines.push({ kind: "hunk", text: line });
    } else if (line.startsWith("+")) {
      f.added++;
      f.lines.push({ kind: "add", new: n++, text: line.slice(1) });
    } else if (line.startsWith("-")) {
      f.removed++;
      f.lines.push({ kind: "del", old: o++, text: line.slice(1) });
    } else if (line.startsWith(" ")) {
      f.lines.push({ kind: "ctx", old: o++, new: n++, text: line.slice(1) });
    }
  }
  return files;
}

window.addEventListener("hashchange", () => { window.scrollTo(0, 0); render(); });
connect();
