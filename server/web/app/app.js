// Maple Factory on the web: review on the go. The same live feed as the apps (/client/connect, signed
// in by the session cookie): the inbox, and a task's plan, mockups, diff, review and proofs, with the
// decisions a person makes on them; new tasks and drafts, and the scratchpad. Nothing here touches
// terminals or machines, except to answer an agent's permission prompt with Yes or No.
//
// Every string from the factory goes in with textContent; agents' screen mockups render in an iframe
// with an empty sandbox (no scripts, no same-origin).

import { markdown, taskResolver } from "./markdown.js";
import { markdownEditor } from "./editor.js";
import { loadCollapsed, toggleCollapsed } from "./sections.js";
import { extend, linesLabel, pick, pickable, picked, relocate, rowsOf, selected, toNote } from "./review.js";
import { bundleStale } from "./update.js";

const state = { me: null, org: "", members: [], goals: [], tasks: new Map(), notes: [], live: false, diffs: new Map(), machines: [], checkLogs: new Map() };
/** The CI check log asked for (`task.checkLog`) and not answered yet: a refusal meanwhile is its answer. */
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
const allTasks = () => [...state.tasks.values()];
/** Links the factory's task IDs (`MF-12`) in rendered Markdown. */
const knownTasks = () => taskResolver(state.tasks.values());
const STATE_TITLE = { drafting: "Drafting", planning: "Planning", awaitingApproval: "Awaiting approval", backlog: "Backlog", building: "Building", reviewing: "Reviewing", merged: "Merged", cancelled: "Cancelled" };
const name = (login) => {
  if (["planner", "builder", "reviewer", "factory"].includes(login)) return login[0].toUpperCase() + login.slice(1);
  if (login === state.me?.login) return "You";
  return state.members.find((m) => m.login === login)?.name || login;
};
const AGENT_TITLE = { claude: "Claude Code", codex: "Codex", shell: "Shell" };
const agentTitle = (agent) => AGENT_TITLE[agent] ?? (agent ? agent[0].toUpperCase() + agent.slice(1) : "");
/** The Claude and Codex marks, 24×24, drawn in currentColor. */
const AGENT_MARKS = {
  claude: { d: "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z" },
  codex: { d: "M8.086 .457 a6.105 6.105 0 0 1 3.046 -.415 c1.333 .153 2.521 .72 3.564 1.7 a.117 .117 0 0 0 .107 .029 c1.408 -.346 2.762 -.224 4.061 .366 l.063 .03 .154 .076 c1.357 .703 2.33 1.77 2.918 3.198 .278 .679 .418 1.388 .421 2.126 a5.655 5.655 0 0 1 -.18 1.631 .167 .167 0 0 0 .04 .155 5.982 5.982 0 0 1 1.578 2.891 c.385 1.901 -.01 3.615 -1.183 5.14 l-.182 .22 a6.063 6.063 0 0 1 -2.934 1.851 .162 .162 0 0 0 -.108 .102 c-.255 .736 -.511 1.364 -.987 1.992 -1.199 1.582 -2.962 2.462 -4.948 2.451 -1.583 -.008 -2.986 -.587 -4.21 -1.736 a.145 .145 0 0 0 -.14 -.032 c-.518 .167 -1.04 .191 -1.604 .185 a5.924 5.924 0 0 1 -2.595 -.622 6.058 6.058 0 0 1 -2.146 -1.781 c-.203 -.269 -.404 -.522 -.551 -.821 a7.74 7.74 0 0 1 -.495 -1.283 6.11 6.11 0 0 1 -.017 -3.064 .166 .166 0 0 0 .008 -.074 .115 .115 0 0 0 -.037 -.064 5.958 5.958 0 0 1 -1.38 -2.202 5.196 5.196 0 0 1 -.333 -1.589 6.915 6.915 0 0 1 .188 -2.132 c.45 -1.484 1.309 -2.648 2.577 -3.493 .282 -.188 .55 -.334 .802 -.438 .286 -.12 .573 -.22 .861 -.304 a.129 .129 0 0 0 .087 -.087 A6.016 6.016 0 0 1 5.635 2.31 C6.315 1.464 7.132 .846 8.086 .457 zm-.804 7.85 a.848 .848 0 0 0 -1.473 .842 l1.694 2.965 -1.688 2.848 a.849 .849 0 0 0 1.46 .864 l1.94 -3.272 a.849 .849 0 0 0 .007 -.854 l-1.94 -3.393 zm5.446 6.24 a.849 .849 0 0 0 0 1.695 h4.848 a.849 .849 0 0 0 0 -1.696 h-4.848 z", evenodd: true },
};
/** An agent's mark as inline SVG, or nothing for an agent without one. */
function agentIcon(agent) {
  const mark = AGENT_MARKS[agent];
  if (!mark) return null;
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  for (const [k, v] of Object.entries({ viewBox: "0 0 24 24", fill: "currentColor", class: "agent-icon", "aria-hidden": "true" })) svg.setAttribute(k, v);
  const path = document.createElementNS(ns, "path");
  path.setAttribute("d", mark.d);
  if (mark.evenodd) path.setAttribute("fill-rule", "evenodd");
  svg.append(path);
  return svg;
}
/** "Builder · ✻ Claude Code": a worker's role and the agent running it. */
const workerLabel = (w) => [`${name(w.role)} · `, agentIcon(w.agent), agentTitle(w.agent)];
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
  if (socket?.readyState === WebSocket.OPEN) return socket.send(JSON.stringify(msg)), true;
  toast("Not connected; try again in a moment.");
  return false;
}

function receive(m) {
  switch (m.type) {
    case "snapshot":
      Object.assign(state, { me: m.me, org: m.org, members: m.members, goals: m.goals, live: true });
      state.tasks = new Map(m.tasks.map((t) => [t.id, t]));
      state.notes = m.notes ?? [];
      state.machines = m.machines ?? [];
      $("org").textContent = m.name || m.org || "Maple Factory";
      showIcon(m.icon);
      status();
      // The first version seen is the bundle this tab loaded; a reconnect after a deploy reports the new one.
      state.loadedVersion ??= m.serverVersion || null;
      if (bundleStale(state.loadedVersion, m.serverVersion)) $("update").hidden = false;
      break;
    case "icon.updated": showIcon(m.icon); return;
    case "name.updated": $("org").textContent = m.name || state.org || "Maple Factory"; return;
    case "task.updated":
      if (!state.tasks.has(m.task.id)) created(m.task);
      notifyMentions(state.tasks.get(m.task.id), m.task);
      state.tasks.set(m.task.id, m.task);
      mergeSent.delete(m.task.id);
      break;
    case "task.removed": state.tasks.delete(m.id); break;
    case "machine.updated":
    case "machine.removed": {
      // Machines change with every step an agent takes; only a prompt starting or ending redraws.
      const before = prompts();
      state.machines = state.machines.filter((x) => x.id !== (m.machine?.id ?? m.id));
      if (m.machine) state.machines.push(m.machine);
      if (prompts() === before) return;
      break;
    }
    case "goal.updated": state.goals = [...state.goals.filter((g) => g.id !== m.goal.id), m.goal]; break;
    case "note.updated": state.notes = [...state.notes.filter((n) => n.id !== m.note.id), m.note]; break;
    case "note.removed": state.notes = state.notes.filter((n) => n.id !== m.id); break;
    case "toast": toast(m.text); break;
    case "checkLog": {
      const key = `${m.id}/${m.check}`;
      // Only into a panel still waiting for it: one closed (or re-run) since doesn't open again.
      if (state.checkLogs.get(key)?.loading) state.checkLogs.set(key, { text: m.text, truncated: m.truncated, failedStep: m.failedStep ?? null, url: m.url ?? null });
      break;
    }
    case "error":
      // A log that couldn't be read says which one (`checkLog:<task>/<check>`) and shows in its panel.
      if (m.requestId?.startsWith("checkLog:")) {
        const key = m.requestId.slice(9);
        if (state.checkLogs.get(key)?.loading) state.checkLogs.set(key, { error: m.message });
        break;
      }
      // The task being created didn't take; let the composer try again. Errors carry no request id, so
      // take one that comes back soon after the create to be about it; any later one leaves it alone.
      if (creating && Date.now() - creating.at < 5_000) createFailed();
      mergeSent.clear(); // a refused Merge or Hold gives its buttons back
      toast(m.message);
      break;
    default: return;
  }
  render();
}

/** The factory's icon (`/icon/<id>`) in the header in place of the leaf, and as the tab's icon; none puts both back. */
const plainFavicon = document.querySelector("link[rel=icon]").href;
function showIcon(link) {
  const leaf = document.querySelector(".brand .leaf");
  leaf.style.backgroundImage = link ? `url("${link}")` : "";
  leaf.classList.toggle("icon", !!link);
  document.querySelector("link[rel=icon]").href = link || plainFavicon;
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

// ---- mentions ----

// Comments mentioning me that I've dismissed from the inbox, kept in this browser.
const DISMISSED_KEY = "maple.dismissedMentions";
const dismissed = new Set((() => { try { return JSON.parse(localStorage.getItem(DISMISSED_KEY) ?? "[]"); } catch { return []; } })());
function dismissMention(id) {
  dismissed.add(id);
  try { localStorage.setItem(DISMISSED_KEY, JSON.stringify([...dismissed].slice(-500))); } catch {}
  render();
}

const mentionsMe = (c) => c.author !== state.me?.login && (c.mentions ?? []).includes(state.me?.login);

/** Each comment that mentions me and isn't dismissed, newest first, with its task. */
function mentions() {
  return [...state.tasks.values()].flatMap((t) => t.comments.filter((c) => mentionsMe(c) && !dismissed.has(c.id)).map((c) => [t, c]))
    .sort((a, b) => b[1].at - a[1].at);
}

/** A browser notification for each comment newly mentioning me, while this tab is in the background. */
function notifyMentions(before, task) {
  if (!before || !document.hidden || typeof Notification === "undefined" || Notification.permission !== "granted") return;
  const seen = new Set(before.comments.map((c) => c.id));
  for (const c of task.comments.filter((c) => !seen.has(c.id) && mentionsMe(c))) {
    const n = new Notification(`${name(c.author)} mentioned you`, { body: `${task.id} · ${task.title}\n${c.text.slice(0, 180)}`, tag: c.id });
    n.onclick = () => {
      window.focus();
      location.hash = `#/t/${task.id}`;
      n.close();
    };
  }
}

/** Ask once, from the inbox (a click away from the page loading), whether to show notifications. */
function askToNotify() {
  if (typeof Notification === "undefined" || Notification.permission !== "default" || askToNotify.asked) return;
  askToNotify.asked = true;
  Notification.requestPermission().catch(() => {});
}

const KINDS = { hand: ["Needs a hand", "cancelled"], question: ["Questions", "awaitingApproval"], plan: ["Plans awaiting approval", "awaitingApproval"], review: ["Ready for review", "reviewing"], ci: ["Failing CI", "cancelled"] };

// ---- views ----

function route() {
  const [hash, query = ""] = (location.hash.replace(/^#/, "") || "/").split("?");
  const task = hash.match(/^\/t\/([A-Z][A-Z0-9]*-\d+)$/);
  const note = hash.match(/^\/notes\/([\w-]+)$/);
  if (task) return { name: "task", nav: "tasks", id: task[1] };
  if (note) return { name: "note", nav: "notes", id: note[1] };
  if (hash === "/new") return { name: "new", nav: "new", note: new URLSearchParams(query).get("note") };
  if (hash === "/notes") return { name: "notes", nav: "notes" };
  return hash === "/tasks" ? { name: "tasks", nav: "tasks" } : { name: "inbox", nav: "inbox" };
}

function render() {
  if (!state.me) return;
  const r = route();
  for (const a of document.querySelectorAll("[data-nav]")) a.classList.toggle("on", a.dataset.nav === r.nav);
  const waiting = [...state.tasks.values()].filter(needsYou).length + mentions().length;
  $("inbox-count").textContent = waiting || "";
  document.title = `${waiting ? `(${waiting}) ` : ""}Maple Factory`;
  const next = { task: () => taskView(r.id), tasks: tasksView, new: () => newTaskView(r), notes: notesView, note: () => noteView(r.id) }[r.name]?.() ?? inboxView();
  // Keep what someone's typing: re-render only around the boxes being typed in.
  mount(next, !!document.activeElement?.closest?.("[data-keep]"));
}
const view = render;

// Sections of the Inbox and Tasks pages folded down to their heading, kept in this browser.
const collapsed = loadCollapsed();

/** A section with a heading that collapses it to "Title · count"; `body()` isn't built while it's collapsed. */
function section(key, title, count, body) {
  const open = !collapsed.has(key);
  const id = `section-${key.replace(/[^\w-]/g, "-")}`;
  return h("section", { class: `section${open ? "" : " closed"}` },
    h("h2", {}, h("button", { type: "button", class: "section-head", "data-section": key, "aria-expanded": String(open), "aria-controls": open ? id : null,
      onclick: () => { toggleCollapsed(collapsed, key); render(); } },
      h("span", { class: "chevron", "aria-hidden": "true" }, "▾"), count == null ? title : `${title} · ${count}`)),
    open && h("div", { id }, body()));
}

function row(t, sub) {
  const goal = goalOf(t);
  return h("a", { class: "item", href: `#/t/${t.id}` },
    h("span", { class: `dot bg-${t.state}` }),
    h("div", {},
      h("div", { class: "title" }, t.title),
      h("div", { class: "sub" }, h("span", { class: "mono" }, t.id), goal ? ` · ${goal.name}` : "", " · ", sub)));
}

/** Its state's title, or "Merging…" (the server's live log while it merges) or the auto-merge countdown. */
function stateLabel(t) {
  if (t.state !== "reviewing") return STATE_TITLE[t.state];
  if (t.liveLog === "Merging…") return "Merging…";
  if (t.mergeAt != null && !t.hand) return h("span", { "data-merge-at": t.mergeAt }, countdownLabel(t.mergeAt));
  return STATE_TITLE[t.state];
}

function inboxView() {
  const groups = new Map();
  for (const t of state.tasks.values()) {
    const n = needsYou(t);
    if (n) groups.set(n.kind, [...(groups.get(n.kind) ?? []), [t, n]]);
  }
  const mentioned = mentions();
  const total = [...groups.values()].reduce((a, g) => a + g.length, 0) + mentioned.length;
  askToNotify();
  return h("div", {},
    h("h1", {}, "Inbox"),
    h("p", { class: "muted" }, total ? `${total} thing${total === 1 ? "" : "s"} waiting on you.` : "Nothing's waiting on you."),
    Object.keys(KINDS).filter((k) => groups.has(k)).map((k) =>
      section(`inbox:${k}`, KINDS[k][0], groups.get(k).length, () => h("div", { class: "list" }, groups.get(k).map(([t, n]) => row(t, n.text))))),
    mentioned.length > 0 && section("inbox:mentions", "Mentions", mentioned.length, () =>
      h("div", { class: "list" }, mentioned.map(([t, c]) => h("div", { class: "item mention-row" },
        row(t, `${name(c.author)} · ${ago(c.at)}: ${c.text.replace(/\s+/g, " ").slice(0, 140)}`),
        h("button", { class: "btn small", onclick: () => dismissMention(c.id) }, "Dismiss"))))),
    !total && h("div", { class: "card empty" }, "When a plan needs your approval, an agent asks something, a change is ready for your review, or someone mentions you, it shows up here."));
}

/** Waiting for a session with nobody on it, as the server's queue reads it (the Mac app's Queued column). */
function isQueued(t) {
  if (t.worker || t.hand || t.question) return false;
  if (t.state === "planning") return true;
  if (t.state === "building") return Boolean(t.waiting);
  return t.state === "reviewing" && t.autoReview?.rounds.at(-1)?.verdict === "inProgress";
}
const rank = (t) => t.queueRank ?? t.createdAt;
const scheduled = (t) => t.startAt != null && t.startAt > Date.now();
const queueLine = (t) => scheduled(t) ? `Starts ${new Date(t.startAt).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}` : t.waiting || "Waiting for a slot";

function tasksView() {
  const drafts = [...state.tasks.values()].filter((t) => t.state === "drafting").sort((a, b) => b.updatedAt - a.updatedAt);
  const queued = [...state.tasks.values()].filter(isQueued).sort((a, b) => rank(a) - rank(b));
  const backlog = [...state.tasks.values()].filter((t) => t.state === "backlog").sort((a, b) => b.updatedAt - a.updatedAt);
  const active = [...state.tasks.values()].filter((t) => !["drafting", "backlog", "merged", "cancelled"].includes(t.state) && !isQueued(t)).sort((a, b) => b.updatedAt - a.updatedAt);
  const done = [...state.tasks.values()].filter((t) => t.state === "merged").sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 10);
  return h("div", {},
    h("h1", {}, "Tasks"),
    drafts.length > 0 && section("tasks:drafts", "Drafts", drafts.length, () => h("div", { class: "list" }, drafts.map((t) => row(t, t.owner === state.me?.login ? `draft · edited ${ago(t.updatedAt)}` : `${name(t.owner)}'s draft`)))),
    queued.length > 0 && section("tasks:queued", "Queued", queued.length, () => h("div", { class: "list" }, queued.map((t, i) => row(t, `#${i + 1} · ${queueLine(t)}`)))),
    backlog.length > 0 && section("tasks:backlog", "Backlog", backlog.length, () => h("div", { class: "list" }, backlog.map((t) => row(t, t.plan.length ? `plan v${t.planVersion} · parked ${ago(t.updatedAt)}` : `not planned · parked ${ago(t.updatedAt)}`)))),
    section("tasks:active", "In flight", active.length, () =>
      active.length ? h("div", { class: "list" }, active.map((t) => row(t, t.waiting || stateLabel(t)))) : h("div", { class: "card empty" }, "Nothing in flight.")),
    done.length > 0 && section("tasks:merged", "Recently merged", null, () => h("div", { class: "list" }, done.map((t) => row(t, `merged ${ago(t.updatedAt)}`)))));
}

// ---- a new task ----

// What's in the composer, so a re-render (or a trip to another page and back) doesn't lose it.
const composer = { key: null, title: "", goal: null, repo: null, brief: "", shareable: false, note: null, busy: false };
let creating = null; // { title, note, at, timer } until its task.updated arrives

const openGoals = () => state.goals.filter((g) => !g.archived);
const reposOf = (g) => (g?.repos?.length ? g.repos : g?.repo ? [g.repo] : []);

function newTaskView(r) {
  // A new trip here (or from another note) starts over; coming back to the same one keeps it.
  const key = r.note ?? "";
  if (composer.key !== key) {
    const note = r.note && state.notes.find((n) => n.id === r.note);
    Object.assign(composer, { key, title: note && note.title !== "Untitled note" ? note.title : "", brief: note?.body ?? "", repo: null, shareable: false, note: r.note ?? null, busy: false });
  }
  const goals = openGoals();
  if (!goals.length) return h("div", {}, h("h1", {}, "New task"), h("div", { class: "card empty" }, state.live ? "There's no goal to add a task to yet. Make one in the Mac app." : "Loading…"));
  if (!goals.some((g) => g.id === composer.goal)) composer.goal = goals[0].id;
  const goal = goals.find((g) => g.id === composer.goal);
  const repos = reposOf(goal);
  if (!repos.includes(composer.repo)) composer.repo = goal.repo ?? repos[0] ?? null;

  // Only the text boxes are kept across re-renders; the selects, checkbox and buttons rebuild from `composer`.
  const title = h("input", { type: "text", "data-keep": "new:title", placeholder: "What should change?", value: composer.title, oninput: (e) => (composer.title = e.target.value) });
  const brief = markdownEditor({ members: () => state.members, tasks: allTasks, value: composer.brief, rows: 10, keep: "new:brief", placeholder: "The brief: what you want and why, what done looks like.", oninput: (e) => (composer.brief = e.target.value) }, h);
  const goalSelect = h("select", { onchange: (e) => { composer.goal = e.target.value; composer.repo = null; render(); } },
    goals.map((g) => h("option", { value: g.id, selected: g.id === composer.goal }, g.name)));
  const repoSelect = repos.length > 1 && h("select", { onchange: (e) => (composer.repo = e.target.value) },
    repos.map((r) => h("option", { value: r, selected: r === composer.repo }, r)));

  const create = (plan) => {
    if (composer.busy) return;
    if (!composer.title.trim()) return toast("A task needs a title."), title.focus();
    // Work out the repo now, from the goal that's picked now.
    const repos = reposOf(state.goals.find((g) => g.id === composer.goal));
    const repo = repos.length > 1 && repos.includes(composer.repo) ? composer.repo : null;
    composer.busy = true;
    creating = { title: composer.title.trim(), note: composer.note && { id: composer.note, title: composer.title.trim() || "Untitled note", body: composer.brief }, at: Date.now(),
      timer: setTimeout(() => { if (composer.busy) createFailed("The factory didn't answer; try again."); }, 15_000) };
    if (!send({ type: "task.create", goal: composer.goal, title: composer.title.trim(), brief: composer.brief, shareable: composer.shareable, plan, tickets: [], repo })) return createFailed();
    render();
  };
  const park = () => {
    if (!composer.title.trim() && !composer.brief.trim()) return toast("There's nothing to save yet.");
    const old = composer.note && state.notes.find((n) => n.id === composer.note);
    const id = composer.note ?? crypto.randomUUID();
    sentNotes.add(id);
    send({ type: "note.save", note: { id, owner: state.me.login, title: composer.title.trim() || "Untitled note", body: composer.brief, updatedAt: 0, taskId: old?.taskId ?? null } });
    composer.key = null;
    location.hash = `#/notes/${id}`;
  };
  const form = h("form", { class: "composer", onsubmit: (e) => e.preventDefault(),
    onkeydown: (e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); create(true); } } },
    h("label", { class: "field" }, h("span", {}, "Title"), title),
    h("div", { class: "fields" },
      h("label", { class: "field" }, h("span", {}, "Goal"), goalSelect),
      repoSelect && h("label", { class: "field" }, h("span", {}, "Repo"), repoSelect)),
    h("div", { class: "field" }, h("span", {}, "Brief"), brief),
    h("label", { class: "checkrow" },
      h("input", { type: "checkbox", checked: composer.shareable, onchange: (e) => (composer.shareable = e.target.checked) }),
      h("span", {}, "Shareable", h("span", { class: "muted" }, ": a teammate's machine can run it, not just yours"))),
    h("div", { class: "actionbar" },
      h("button", { type: "button", class: "btn", onclick: park, disabled: composer.busy }, "Save to scratchpad"),
      h("span", { class: "spacer" }),
      h("button", { type: "button", class: "btn", onclick: () => create(false), disabled: composer.busy }, "Save draft"),
      h("button", { type: "button", class: "btn plan", onclick: () => create(true), disabled: composer.busy, title: "⌘↩" },
        composer.busy ? "Creating…" : "Send to planning", h("kbd", {}, "⌘↩"))));
  return h("div", {},
    h("div", { class: "row muted" }, h("a", { href: composer.note ? `#/notes/${composer.note}` : "#/tasks" }, composer.note ? "← Note" : "← Tasks")),
    h("h1", {}, "New task"),
    form);
}

/** A task appeared: if it's the one just composed here, open it, and mark the note it came from. */
function created(t) {
  if (!creating || t.owner !== state.me?.login || t.title !== creating.title) return;
  // The note's save went out before the task.create, so it's normally here; if not, link what was composed from it.
  const from = creating.note;
  const note = from && (state.notes.find((n) => n.id === from.id) ?? { ...from, owner: state.me.login, updatedAt: 0 });
  if (note) send({ type: "note.save", note: { ...note, taskId: t.id } });
  clearTimeout(creating.timer);
  creating = null;
  Object.assign(composer, { key: null, busy: false });
  location.hash = `#/t/${t.id}`;
}

function createFailed(message) {
  clearTimeout(creating?.timer);
  creating = null;
  composer.busy = false;
  if (message) toast(message);
  render();
}

// ---- the scratchpad ----

// What's typed into a note, ahead of the save that's on its way.
const noteText = new Map(); // id → { title, body }
const noteSaves = new Map(); // id → timer
const sentNotes = new Set(); // ids a note.save has gone out for, confirmed or not

function notesView() {
  const notes = [...state.notes].sort((a, b) => b.updatedAt - a.updatedAt);
  return h("div", {},
    h("div", { class: "row" }, h("h1", { style: "flex:1" }, "Scratchpad"), h("button", { class: "btn", onclick: newNote }, "New note")),
    h("p", { class: "muted" }, "Notes only you can see, for ideas that aren't tasks yet."),
    notes.length
      ? h("div", { class: "list" }, notes.map((n) => h("a", { class: "item note", href: `#/notes/${n.id}` },
        h("div", { style: "flex:1;min-width:0" },
          h("div", { class: "title" }, n.title || "Untitled note"),
          h("div", { class: "sub" }, `${ago(n.updatedAt)} · `, preview(n.body) || "Empty")),
        n.taskId && h("span", { class: "pill tag" }, `became ${n.taskId}`))))
      : h("div", { class: "card empty" }, "Nothing jotted down yet."));
}
const preview = (body) => body.replace(/\s+/g, " ").trim().slice(0, 120);

function newNote() {
  const id = crypto.randomUUID();
  noteText.set(id, { title: "", body: "" });
  location.hash = `#/notes/${id}`;
}

function saveNote(id, now) {
  clearTimeout(noteSaves.get(id));
  noteSaves.delete(id);
  const go = () => {
    noteSaves.delete(id);
    const text = noteText.get(id);
    const note = state.notes.find((n) => n.id === id);
    if (!text) return;
    sentNotes.add(id);
    send({ type: "note.save", note: { id, owner: state.me.login, title: text.title.trim() || "Untitled note", body: text.body, updatedAt: 0, taskId: note?.taskId ?? null } });
  };
  if (now) go();
  else noteSaves.set(id, setTimeout(go, 600));
}

const deleting = new Set(); // notes asking "Delete it?"

function noteView(id) {
  const note = state.notes.find((n) => n.id === id);
  if (!note && !noteText.has(id)) return h("div", {}, h("div", { class: "row muted" }, h("a", { href: "#/notes" }, "← Scratchpad")),
    h("div", { class: "card empty" }, state.live ? "That note isn't there any more." : "Loading…"));
  if (!noteText.has(id)) noteText.set(id, { title: note.title === "Untitled note" ? "" : note.title, body: note.body });
  const text = noteText.get(id);
  const edit = (field) => (e) => {
    text[field] = e.target.value;
    saveNote(id);
    $("note-status").textContent = "Saving…";
  };
  const title = h("input", { type: "text", class: "note-title", placeholder: "Untitled note", value: text.title, oninput: edit("title") });
  const body = markdownEditor({ members: () => state.members, tasks: allTasks, value: text.body, placeholder: "Jot it down…", minHeight: "50vh", oninput: edit("body"), onblur: () => noteSaves.has(id) && saveNote(id, true) }, h);
  const turn = () => {
    if (!text.title.trim() && !text.body.trim()) return toast("Write something first.");
    if (noteSaves.has(id)) saveNote(id, true);
    // Fill the composer from what's typed here, which may be ahead of state.notes (or not in it at all yet).
    Object.assign(composer, { key: id, title: text.title.trim(), brief: text.body, repo: null, shareable: false, note: id, busy: false });
    location.hash = `#/new?note=${id}`;
  };
  const remove = () => {
    deleting.delete(id);
    clearTimeout(noteSaves.get(id));
    noteSaves.delete(id);
    noteText.delete(id);
    // A save that's gone out but not come back would bring the note back, so delete it then too.
    if (note || sentNotes.has(id)) send({ type: "note.delete", id });
    sentNotes.delete(id);
    location.hash = "#/notes";
  };
  const saved = noteSaves.has(id) ? "Saving…" : note ? `Saved ${ago(note.updatedAt)}` : "Not saved yet";
  return h("div", {},
    h("div", { class: "row muted" }, h("a", { href: "#/notes" }, "← Scratchpad"), h("span", { class: "spacer" }),
      note?.taskId && h("a", { class: "pill tag", href: `#/t/${note.taskId}` }, `became ${note.taskId}`)),
    h("div", { class: "note-editor", "data-keep": `note:${id}` }, title, body),
    h("div", { class: "actionbar" },
      h("span", { class: "muted", id: "note-status", style: "font-size:13px" }, saved),
      h("span", { class: "spacer" }),
      deleting.has(id)
        ? [h("span", { class: "muted", style: "font-size:13px" }, "Delete this note?"),
          h("button", { class: "btn", onclick: () => { deleting.delete(id); render(); } }, "Keep it"),
          h("button", { class: "btn danger", onclick: remove }, "Delete")]
        : [h("button", { class: "btn", onclick: () => { deleting.add(id); render(); } }, "Delete"),
          h("button", { class: "btn primary", onclick: turn }, "Turn into task")]));
}

function mount(next, keepCompose) {
  const main = $("main");
  // Moving the box being typed in blurs it, so put the focus and selection back after.
  const active = document.activeElement;
  const range = active && "selectionStart" in active ? [active.selectionStart, active.selectionEnd] : null;
  if (keepCompose) {
    // Swap everything but the boxes being typed in.
    const kept = new Map([...main.querySelectorAll("[data-keep]")].map((el) => [el.dataset.keep, el]));
    for (const slot of next.querySelectorAll("[data-keep]")) {
      const old = kept.get(slot.dataset.keep);
      if (old) slot.replaceWith(old);
    }
  }
  // A proof's image or video stays the same element, so a video keeps playing through updates.
  const media = new Map([...main.querySelectorAll("[data-media]")].map((el) => [el.dataset.media, el]));
  for (const slot of next.querySelectorAll("[data-media]")) {
    const old = media.get(slot.dataset.media);
    if (old) slot.replaceWith(old);
  }
  main.replaceChildren(next);
  if (active && active !== document.activeElement && main.contains(active)) {
    active.focus({ preventScroll: true });
    if (range) try { active.setSelectionRange(...range); } catch {}
  }
  // A section heading is rebuilt on every render; keep the keyboard on it.
  const head = active?.dataset?.section;
  if (head) main.querySelector(`[data-section="${CSS.escape(head)}"]`)?.focus({ preventScroll: true });
}

// ---- a task ----

const taskTabs = new Map(); // id → "overview" | "diff"

function taskView(id) {
  const t = state.tasks.get(id);
  if (!t) return h("div", { class: "card empty" }, state.live ? `There's no task ${id}.` : "Loading…");
  const goal = goalOf(t);
  const tab = taskTabs.get(id) ?? "overview";
  // Parked in the backlog: as far as its plan got.
  const reached = t.state === "cancelled" ? -1 : t.state === "backlog" ? (t.plan.length ? 2 : 0) : STATES.indexOf(t.state);
  return h("div", {},
    h("div", { class: "row muted" }, h("a", { href: "#/" }, "← Inbox"), h("span", { class: "spacer" }), h("span", { class: "mono" }, t.id)),
    h("h1", {}, t.title),
    h("div", { class: "row" },
      h("span", { class: `pill s-${t.state}` }, stateLabel(t)),
      ownerControl(t),
      h("span", { class: "muted" }, `${goal?.name ?? ""}${(goal?.repos?.length ?? 0) > 1 ? ` · ${t.repo ?? goal.repo}` : ""} · updated ${ago(t.updatedAt)}`)),
    (t.after ?? []).length > 0 && h("div", { class: "muted", style: "font-size:13px;margin-top:4px" }, "Builds on ",
      t.after.map((id, i) => [i ? ", " : "", h("a", { href: `#/t/${id}` }, id)])),
    effortLine(t),
    h("div", { class: "stepper" }, STATES.map((s, i) => h("span", { class: i <= reached ? `bg-${STATES[Math.min(i, reached)]}` : "" }))),
    t.waiting && h("p", { class: "muted" }, t.waiting),
    t.liveLog && !t.waiting && t.worker && h("p", { class: "muted" }, workerLabel(t.worker), `: ${t.liveLog}`),
    promptCard(t),
    t.hand && handCard(t),
    t.question && !t.hand && questionCard(t),
    // A backlog task that was never planned is still a draft to refine.
    (t.state === "drafting" || (t.state === "backlog" && !t.plan.length)) && t.owner === state.me?.login ? draftEditor(t) : decisions(t),
    t.effort && effortCard(t),
    h("div", { class: "tabs", style: "margin-top:22px" },
      h("button", { class: `tab${tab === "overview" ? " on" : ""}`, onclick: () => { taskTabs.set(id, "overview"); render(); } }, "Overview"),
      t.diff && h("button", { class: `tab${tab === "diff" ? " on" : ""}`, onclick: () => { taskTabs.set(id, "diff"); render(); } }, `Diff +${t.diff.added} −${t.diff.removed}`)),
    tab === "diff" ? diffView(t) : overview(t));
}

// ---- efforts: tasks in a goal that share a name, like an epic ----

const effortEdits = new Map(); // task id → the effort name being typed

/** Every task in `t`'s goal that's part of `effort`, in id order (ATL-9 before ATL-10). */
const effortTasks = (t, effort) => [...state.tasks.values()].filter((x) => x.goal === t.goal && x.effort === effort)
  .sort((a, b) => a.id.localeCompare(b.id, undefined, { numeric: true }));

// Its owner: a select for its owner or an admin (who can give it to anyone), Take over for everyone else.
function ownerControl(t) {
  const me = state.me?.login;
  const open = t.state !== "merged" && t.state !== "cancelled";
  const assign = (owner) => owner && owner !== t.owner && send({ type: "task.assign", id: t.id, owner });
  if (!open) return h("span", { class: "muted" }, `${name(t.owner)} ·`);
  const canGive = t.owner === me || state.me?.role === "admin";
  return h("span", { class: "row", style: "gap:6px" },
    canGive
      ? h("select", { title: "Who owns it", onchange: (e) => assign(e.target.value) },
          state.members.map((m) => h("option", { value: m.login, selected: m.login === t.owner }, m.login === me ? `${m.name || m.login} (you)` : m.name || m.login)))
      : h("span", { class: "muted" }, name(t.owner)),
    t.owner !== me && h("button", { class: "btn small", onclick: () => assign(me) }, "Take over"),
    h("span", { class: "muted" }, "·"));
}

function effortLine(t) {
  const typed = effortEdits.get(t.id);
  if (typed == null) {
    return h("div", { class: "muted", style: "font-size:13px;margin-top:4px" }, "Effort: ",
      t.effort ? h("b", {}, t.effort) : "none", " · ",
      h("a", { href: "javascript:void 0", onclick: () => { effortEdits.set(t.id, t.effort ?? ""); render(); document.querySelector(`[data-keep="${t.id}:effort"] input`)?.focus(); } },
        t.effort ? "Change" : "Add to an effort"));
  }
  const efforts = [...new Set([...state.tasks.values()].filter((x) => x.goal === t.goal && x.effort).map((x) => x.effort))].sort();
  const save = () => {
    const name = (effortEdits.get(t.id) ?? "").trim();
    if (name !== (t.effort ?? "") && !send({ type: "task.edit", id: t.id, effort: name })) return;
    effortEdits.delete(t.id);
    render();
  };
  const cancel = () => { effortEdits.delete(t.id); render(); };
  return h("form", { class: "row", "data-keep": `${t.id}:effort`, style: "font-size:13px;margin-top:6px;gap:6px", onsubmit: (e) => { e.preventDefault(); save(); } },
    h("span", { class: "muted" }, "Effort"),
    h("input", { type: "text", list: `efforts-${t.id}`, placeholder: "A name, like Login revamp; empty for none", value: typed, style: "flex:1;min-width:0",
      oninput: (e) => effortEdits.set(t.id, e.target.value), onkeydown: (e) => { if (e.key === "Escape") cancel(); } }),
    h("datalist", { id: `efforts-${t.id}` }, efforts.map((name) => h("option", { value: name }))),
    h("button", { class: "btn small", type: "submit" }, "Save"),
    h("button", { class: "btn small", type: "button", onclick: cancel }, "Cancel"));
}

function effortCard(t) {
  const tasks = effortTasks(t, t.effort);
  const counted = tasks.filter((x) => x.state !== "cancelled");
  return [h("h2", { class: "row" }, h("span", {}, `Effort · ${t.effort}`), h("span", { class: "spacer" }),
      h("span", { style: "text-transform:none;letter-spacing:0;font-weight:500" }, `${counted.filter((x) => x.state === "merged").length} of ${counted.length} merged`)),
    h("div", { class: "list" }, tasks.map((x) => h("a", { class: `item${x.id === t.id ? " current" : ""}`, href: `#/t/${x.id}` },
      h("span", { class: `dot bg-${x.state}` }),
      h("div", { style: "flex:1;min-width:0" },
        h("div", { class: "title" }, x.title),
        h("div", { class: "sub" }, h("span", { class: "mono" }, x.id), x.id === t.id ? " · this task" : "")),
      h("span", { class: `pill s-${x.state}` }, STATE_TITLE[x.state]))))];
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

/** The task's worker session's activity while it's waiting for someone, from its machine. */
function waitingActivity(t) {
  const w = t.worker;
  const a = w && state.machines.find((m) => m.id === w.machine)?.sessions.find((s) => s.session.id === w.session)?.activity;
  return a?.state === "waiting" ? a : null;
}

/** Which tasks are stopped at a prompt, and since when: what `receive` compares to skip a redraw. */
const prompts = () => [...state.tasks.values()].map((t) => waitingActivity(t)?.at ?? "").join();

const answering = new Map(); // task id → the activity `at` answered, while it moves on

function promptCard(t) {
  const a = waitingActivity(t);
  const p = a?.question?.permission;
  if (!a || (!p && t.hand)) return null;
  const busy = answering.get(t.id) === a.at;
  const answer = (choice) => {
    if (busy || !send({ type: "task.answerPrompt", id: t.id, choice })) return;
    answering.set(t.id, a.at);
    // Refused, or the keypress was lost: the buttons come back.
    setTimeout(() => { if (answering.get(t.id) === a.at) { answering.delete(t.id); render(); } }, 10_000);
    render();
  };
  return h("div", { class: "callout question" },
    h("b", {}, workerLabel(t.worker), " is waiting on you"),
    p ? [
      h("p", { style: "margin:6px 0 0" }, `Wants to run ${p.tool}: ${p.summary}`),
      p.detail && h("pre", { class: "prompt-detail" }, p.detail),
      p.warning && h("p", { class: "muted", style: "margin:6px 0 0" }, `⚠ ${p.warning}`),
      h("div", { class: "actions" },
        h("button", { class: "btn go", disabled: busy, onclick: () => answer("yes") }, busy ? "Answering…" : "Yes"),
        h("button", { class: "btn", disabled: busy, onclick: () => answer("no") }, "No")),
    ] : h("p", { style: "margin:6px 0 0" }, `${a.message ?? "It's waiting for you in its session."} Answer it in the session.`));
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
    buttons.push(h("button", { class: "btn go", disabled: t.approvals.includes(me), onclick: () => approvePlan(t) },
      t.approvals.includes(me) ? "You approved it" : "Approve plan"));
    buttons.push(h("span", { class: "muted", style: "align-self:center;font-size:13px" }, `${t.approvals.length} of ${t.approvalsNeeded} approvals`));
  }
  if (t.state === "awaitingApproval" || t.state === "drafting") {
    buttons.push(h("button", { class: "btn", onclick: () => send({ type: "task.backlog", id: t.id }) }, "Send to backlog"));
  }
  if (t.state === "backlog") {
    // Nothing runs on it until it's picked up: its plan approved, or planned (again).
    if (t.plan.length) buttons.push(h("button", { class: "btn go", onclick: () => approvePlan(t) }, "Approve & build"));
    buttons.push(h("button", { class: "btn", onclick: () => send({ type: "task.plan", id: t.id }) }, "Send to planning"));
    buttons.push(h("span", { class: "muted", style: "align-self:center;font-size:13px" }, "In the backlog: nothing runs until you pick it up."));
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
    const countdown = mergeCountdown(t);
    if (merging(t)) {
      // The factory has it (or a click is on its way): nothing to click until it lands.
      buttons.push(h("button", { class: "btn go", disabled: true }, "Merging…"));
    } else if (countdown) {
      // The factory merges when the fill drains: its delay is the part of the window already gone,
      // so a re-render (or a reload) carries on from where it is.
      buttons.push(h("button", {
        class: "btn go countdown", "aria-disabled": "true", "data-merge-at": t.mergeAt, "data-locks": "",
        style: `--grace:${countdown.total}ms;--used:${countdown.total - countdown.left}ms`,
      }, countdownLabel(t.mergeAt)));
      buttons.push(h("button", { class: "btn", onclick: () => sendMerge(t, "task.holdMerge") }, "Hold"));
      buttons.push(h("button", { class: "btn", onclick: () => sendMerge(t, "task.merge") }, "Merge now"));
    } else if (passed && t.reviews.length >= t.reviewsNeeded && t.hand?.reason !== "mergeFailed") {
      // A failed merge's hand carries the ways forward instead.
      buttons.push(h("button", { class: "btn go", disabled: failing || pending, onclick: () => sendMerge(t, "task.merge") },
        failing ? "CI is failing" : pending ? "Waiting for CI" : "Merge"));
    }
    if (failing) buttons.push(h("button", { class: "btn", onclick: () => send({ type: "task.rerunChecks", id: t.id }) }, "Re-run failed"));
    if (!passed) buttons.push(h("span", { class: "muted", style: "align-self:center;font-size:13px" }, "The review agent is still on it."));
  }
  if (isQueued(t)) {
    buttons.push(h("button", { class: "btn", onclick: () => send({ type: "task.queue", id: t.id, before: "top" }) }, "Move to top"));
    if (scheduled(t)) buttons.push(h("button", { class: "btn", onclick: () => send({ type: "task.queue", id: t.id, before: "top", clearSchedule: true }) }, "Start now"));
  }
  if (t.state !== "merged") {
    // Waiting on its plan's approval or in the backlog, nothing is running to retry; requesting a change plans again.
    if (!["drafting", "awaitingApproval", "backlog"].includes(t.state)) buttons.push(h("button", { class: "btn", onclick: () => send({ type: "task.retry", id: t.id }) }, "Retry"));
    if (t.state !== "cancelled") buttons.push(h("button", { class: "btn danger", onclick: () => { cancelling.add(t.id); render(); } }, "Cancel…"));
  }
  const steerable = ["planning", "awaitingApproval", "building", "reviewing"].includes(t.state) || (t.state === "backlog" && t.plan.length > 0);
  const [placeholder, label] = {
    awaitingApproval: ["Ask for a change to the plan…", "Request change"],
    backlog: ["Ask for a change to the plan; it's planned again…", "Request change"],
    reviewing: ["What should change before it merges? The builder picks it up.", "Request changes"],
  }[t.state] ?? ["Steer it: what should change?", "Request change"];
  const renaming = t.suggestedTitle && (t.state === "backlog" || (t.state === "awaitingApproval" && !t.approvals.includes(me)));
  return h("div", {},
    renaming && renameRow(t),
    buttons.length > 0 && h("div", { class: "actions" }, buttons),
    cancelling.has(t.id) && t.state !== "cancelled" && t.state !== "merged" && cancelCard(t),
    steerable && compose(t, "steer", placeholder, label, (text) => send({ type: "task.steer", id: t.id, text })));
}

/** The planner's proposed title: taken once the plan is approved, unless the approver keeps the current one. */
function renameRow(t) {
  const keep = keepingTitle.has(t.id);
  return h("div", { class: `rename${keep ? " keep" : ""}` },
    h("span", { class: "muted" }, "Renames to"),
    h("b", { class: "to" }, t.suggestedTitle),
    h("s", { class: "from" }, t.title),
    h("label", {},
      h("input", { type: "checkbox", checked: keep, onchange: (e) => { e.target.checked ? keepingTitle.add(t.id) : keepingTitle.delete(t.id); render(); } }),
      " Keep current title"));
}

function approvePlan(t) {
  const keepTitle = !!t.suggestedTitle && keepingTitle.has(t.id);
  keepingTitle.delete(t.id);
  send({ type: "task.approvePlan", id: t.id, ...(keepTitle ? { keepTitle } : {}) });
}

/** The auto-merge counting down on a task: the whole window and what's left of it (ms), or null. The
 *  window starts at the factory's "will auto-merge" event; without one it's taken as the default 10s. */
function mergeCountdown(t) {
  // Long past due, it isn't merging after all: show the plain Merge button again.
  if (t.state !== "reviewing" || !t.mergeAt || Date.now() - t.mergeAt > 15_000) return null;
  const started = t.events.findLast((e) => e.who === "factory" && e.text.startsWith("will auto-merge"))?.at;
  const left = Math.max(0, t.mergeAt - Date.now());
  return { total: Math.max(started ? t.mergeAt - started : 10_000, left, 1), left };
}

/** Merging, as far as its buttons go: the server says so, a Merge or Hold is on its way, or its
 *  countdown ran out (the server says Merging… a moment later). */
function merging(t) {
  if (t.state !== "reviewing") return false;
  if (t.liveLog === "Merging…" || mergeSent.has(t.id)) return true;
  const countdown = !t.hand && mergeCountdown(t);
  return !!countdown && countdown.left === 0;
}

/** Sends a Merge or Hold and locks its buttons until the task's next update (or 30s, if none comes). */
function sendMerge(t, type) {
  if (mergeSent.has(t.id) || !send({ type, id: t.id })) return;
  const at = Date.now();
  mergeSent.set(t.id, at);
  setTimeout(() => { if (mergeSent.get(t.id) === at) { mergeSent.delete(t.id); render(); } }, 30_000);
  render();
}

function countdownLabel(mergeAt) {
  const left = Math.ceil((mergeAt - Date.now()) / 1000);
  return left > 0 ? `Merging in ${left}s` : "Merging…";
}

// A countdown's label ticks on its own, between the renders that updates bring.
// A countdown button that reaches 0 redraws once, so Hold and Merge now drop out at once.
setInterval(() => {
  let due = false;
  for (const el of document.querySelectorAll("[data-merge-at]")) {
    el.textContent = countdownLabel(Number(el.dataset.mergeAt));
    if (el.hasAttribute("data-locks") && Number(el.dataset.mergeAt) <= Date.now()) due = true;
  }
  if (due) render();
}, 250);

const keepingTitle = new Set(); // ids whose approver ticked "Keep current title"
const cancelling = new Set(); // ids whose Cancel… is asking "are you sure?"
const mergeSent = new Map(); // id → when its Merge or Hold was sent, until the task's next update

/** Asks before cancelling, saying what it stops. */
function cancelCard(t) {
  const stops = [
    // The same list as the Mac app's cancel confirmation.
    t.worker ? `its running ${t.worker.role} session` : (t.state === "planning" || t.state === "building" || t.liveLog) && "its running session",
    t.pr && (t.pr.state === "open" || t.pr.state === "draft") && `its open PR #${t.pr.number}`,
    t.state === "awaitingApproval" && "the pending plan approval",
    t.state === "reviewing" && t.pr?.state !== "merged" && "the pending review",
    (t.question || t.hand) && "the open question to you",
  ].filter(Boolean);
  const list = stops.length > 1 ? `${stops.slice(0, -1).join(", ")} and ${stops.at(-1)}` : stops[0];
  const done = () => { cancelling.delete(t.id); render(); };
  return h("div", { class: "callout hand" },
    h("b", {}, `Cancel ${t.id}?`),
    h("p", { style: "margin:6px 0 0" }, `${list ? `This stops ${list}. ` : ""}Its branch stays, and you can pick it back up with Retry.`),
    h("div", { class: "actions" },
      h("button", { class: "btn danger solid", onclick: () => { send({ type: "task.cancel", id: t.id }); done(); } }, "Cancel task"),
      h("button", { class: "btn", onclick: done }, "Keep working")));
}

function compose(t, key, placeholder, label, submit) {
  const go = () => {
    const text = editor.textarea.value.trim();
    if (!text) return;
    if (submit(text) === false) return;
    editor.clear();
  };
  const editor = markdownEditor({ members: () => state.members, tasks: allTasks, placeholder, rows: 2, onsubmit: go }, h);
  return h("div", { class: "compose", "data-keep": `${t.id}:${key}` }, editor, h("div", {}, h("button", { class: "btn small", onclick: go }, label)));
}

// What's typed into a draft's editor, until it's saved.
const draftEdits = new Map(); // id → { title, brief }

function draftEditor(t) {
  const edits = draftEdits.get(t.id) ?? { title: t.title, brief: t.brief };
  draftEdits.set(t.id, edits);
  const dirty = () => edits.title.trim() !== t.title || edits.brief !== t.brief;
  const title = h("input", { type: "text", placeholder: "Title", value: edits.title, oninput: (e) => { edits.title = e.target.value; mark(); } });
  const brief = markdownEditor({ members: () => state.members, tasks: allTasks, value: edits.brief, rows: 8, placeholder: "The brief: what you want and why, what done looks like.", oninput: (e) => { edits.brief = e.target.value; mark(); } }, h);
  const status = h("span", { class: "muted", style: "font-size:13px" });
  const mark = () => (status.textContent = dirty() ? "Unsaved changes" : "");
  mark();
  const save = () => {
    if (!edits.title.trim()) return toast("A task needs a title."), false;
    if (dirty() && !send({ type: "task.edit", id: t.id, title: edits.title.trim(), brief: edits.brief })) return false;
    status.textContent = "";
    return true;
  };
  const plan = () => {
    if (!save()) return;
    send({ type: "task.plan", id: t.id });
    draftEdits.delete(t.id);
  };
  const cancel = () => {
    cancelling.delete(t.id);
    draftEdits.delete(t.id);
    send({ type: "task.cancel", id: t.id });
  };
  return h("div", { class: "card draft" },
    h("div", { class: "note-editor", "data-keep": `${t.id}:draft`,
      onkeydown: (e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); save(); } } },
      h("label", { class: "field" }, h("span", {}, "Title"), title),
      h("div", { class: "field" }, h("span", {}, "Brief"), brief)),
    h("div", { class: "actionbar" },
      cancelling.has(t.id)
        ? [h("span", { class: "muted", style: "font-size:13px" }, "Cancel this draft?"),
          h("button", { class: "btn", onclick: () => { cancelling.delete(t.id); render(); } }, "Keep it"),
          h("button", { class: "btn danger", onclick: cancel }, "Cancel draft")]
        : h("button", { class: "btn", onclick: () => { cancelling.add(t.id); render(); } }, "Cancel draft"),
      status,
      h("span", { class: "spacer" }),
      h("button", { class: "btn", onclick: save }, "Save"),
      t.state === "drafting" && h("button", { class: "btn", onclick: () => save() && send({ type: "task.backlog", id: t.id }) }, "Send to backlog"),
      h("button", { class: "btn plan", onclick: plan }, "Send to planning")));
}

function overview(t) {
  const editing = (t.state === "drafting" || (t.state === "backlog" && !t.plan.length)) && t.owner === state.me?.login;
  return h("div", {},
    t.brief && !editing && [h("h2", {}, "Brief"), h("div", { class: "card" }, markdown(t.brief, h, knownTasks()))],
    t.autoReview && t.autoReview.rounds.length > 0 && review(t),
    t.pr && pull(t),
    t.mockups.length > 0 && [h("h2", {}, "Mockups"), t.mockups.map((m) => mockup(t, m))],
    t.plan.length > 0 && [h("h2", {}, `Plan · v${t.planVersion}`), h("div", { class: "card" },
      h("ol", { class: "steps" }, t.plan.map((s) => h("li", { class: s.progress === "done" ? "done" : s.progress === "active" ? "active" : "" },
        h("div", {}, s.text, s.file && h("div", { class: "mono muted" }, s.file))))))],
    (t.followUps ?? []).length > 0 && [h("h2", {}, "In the goal's other repos"), h("div", { class: "card" },
      t.followUps.map((f) => h("div", { class: "check" }, h("div", {},
        h("b", {}, f.title), h("div", { class: "mono muted" }, f.repo),
        f.task ? h("a", { href: `#/t/${f.task}` }, f.task) : h("span", { class: "faint" }, "A task of its own once the plan is approved")))))],
    t.doneWhen.length > 0 && [h("h2", {}, "Done when"), h("div", { class: "card" }, t.doneWhen.map((d, i) => doneItem(t, d, i)))],
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
      : pr.checks.map((c) => ciCheck(t, c)))];
}

/** A CI check: its link on GitHub, Log (read from GitHub into a panel below it) and Re-run once it's finished. */
function ciCheck(t, c) {
  const pr = t.pr;
  const key = `${t.id}/${c.name}`;
  const log = state.checkLogs.get(key);
  const finished = c.status === "passed" || c.status === "failed";
  const href = c.url || (pr.url && `${pr.url}/checks`);
  const toggleLog = () => {
    if (log && !log.loading) state.checkLogs.delete(key);
    else if (!log && send({ type: "task.checkLog", id: t.id, check: c.name })) state.checkLogs.set(key, { loading: true });
    render();
  };
  // The log shown is the old run's; a new run has its own, so close it.
  const rerun = () => {
    if (!send({ type: "task.rerunCheck", id: t.id, check: c.name })) return;
    state.checkLogs.delete(key);
    toast(`Running ${c.name} again`);
    render();
  };
  return h("div", { class: "check ci-check" },
    h("span", { class: `mark ${c.status === "passed" ? "ok" : c.status === "failed" ? "bad" : "wait"}` }, c.status === "passed" ? "✓" : c.status === "failed" ? "✕" : "•"),
    h("div", { style: "flex:1;min-width:0" },
      h("div", { class: "row" },
        href ? h("a", { href, target: "_blank", rel: "noopener", title: `${c.name} on GitHub` }, c.name) : c.name,
        h("span", { class: "spacer" }),
        h("span", { class: "muted" }, c.duration ?? c.status),
        pr.url && c.status !== "queued" && h("button", { class: "btn small", onclick: toggleLog }, log && !log.loading ? "Hide log" : "Log"),
        pr.url && finished && (pr.state === "open" || pr.state === "draft") && t.state !== "merged" && t.state !== "cancelled" &&
          h("button", { class: "btn small", onclick: rerun }, "Re-run"),
        href && h("a", { class: "btn small", href, target: "_blank", rel: "noopener" }, "GitHub ↗")),
      log && checkLogPanel(log)));
}

function checkLogPanel(log) {
  if (log.loading) return h("p", { class: "muted", style: "margin:8px 0 0" }, "Reading the log from GitHub…");
  if (log.error) return h("p", { class: "muted", style: "margin:8px 0 0" }, log.error);
  const lines = log.text.replace(/\n+$/, "").split("\n").filter((l) => !l.startsWith("##[endgroup]"));
  const pre = h("pre", { class: "check-log", onscroll: () => (log.scrollTop = pre.scrollTop) }, lines.map((l) =>
    l.startsWith("##[group]") ? h("div", { class: "step" }, "▸ ", l.slice(9))
      : l.includes("##[error]") ? h("div", { class: "error" }, "Error: ", l.replace("##[error]", ""))
        : h("div", {}, l || " ")));
  // Opens at the first error, a few lines above it; a redraw keeps where it was scrolled to.
  requestAnimationFrame(() => {
    const err = pre.querySelector(".error");
    if (log.scrollTop != null) pre.scrollTop = log.scrollTop;
    else if (err) pre.scrollTop = Math.max(0, err.offsetTop - pre.offsetTop - 80);
  });
  return h("div", { style: "margin-top:8px" },
    (log.failedStep || log.truncated) && h("div", { class: "row muted", style: "font-size:13px;margin-bottom:6px" },
      log.failedStep && h("b", { class: "bad-text" }, `✕ ${log.failedStep}`), h("span", { class: "spacer" }), log.truncated && "Showing the end of the log"),
    pre);
}

const mockupAsking = new Set(); // "<task>:<mockup>" whose Request a change box is open

function mockup(t, m) {
  const body = m.kind === "terminal"
    ? h("div", { class: "terminal" }, m.lines.map((l) => h("div", { class: l.style }, l.text || " ", l.callout && h("span", { class: "callout-n" }, l.callout))))
    : h("div", { class: "browser" }, h("div", { class: "url" }, m.url ?? m.title),
      fitted(h("div", { class: "mockup-fit" }, h("iframe", { class: "mockup-frame", sandbox: "", srcdoc: m.html ?? "", title: m.title, loading: "lazy" }))));
  return h("div", { style: "margin-bottom:14px" },
    h("div", { class: "row", style: "margin-bottom:6px" }, h("b", {}, m.title), h("span", { class: "muted" }, m.status === "approved" ? "· approved" : m.status === "changesRequested" ? "· changes asked" : "")),
    body,
    m.notes.length > 0 && h("ol", { class: "muted", style: "margin:8px 0 0;padding-left:20px;font-size:14px" }, m.notes.map((n) => h("li", {}, n))),
    mockupChange(t, m));
}

/** Ask for a change to a mockup, as the Mac app does: only while the plan is open, the same rule as
 *  the server. Awaiting approval, the planner revises the plan; planning, the planner takes it now. */
function mockupChange(t, m) {
  if (t.state !== "awaitingApproval" && t.state !== "planning") return null;
  const key = `${t.id}:${m.id}`;
  if (!mockupAsking.has(key)) {
    return h("div", { style: "margin-top:8px" },
      h("button", { class: "btn small", onclick: () => { mockupAsking.add(key); render(); document.querySelector(`[data-keep="${t.id}:mockup:${m.id}"] textarea`)?.focus(); } }, "Request a change"));
  }
  const box = compose(t, `mockup:${m.id}`, `What should change in "${m.title}"?`, "Request change", (text) => {
    if (!send({ type: "task.mockupChange", id: t.id, mockup: m.id, text })) return false;
    mockupAsking.delete(key);
    render();
  });
  // Cancel goes next to compose's own button.
  box.lastChild.classList.add("row");
  box.lastChild.prepend(h("button", { class: "btn small", onclick: () => { mockupAsking.delete(key); render(); } }, "Cancel"));
  return box;
}

/** On a phone a mockup renders 800px wide and scales down by --fit to its box (app.css). */
// A re-render drops the old box, which reports a size of 0 on its way out: let go of it then.
const fit = new ResizeObserver((entries) => {
  for (const e of entries) e.target.isConnected ? e.target.style.setProperty("--fit", Math.min(1, e.contentRect.width / 800)) : fit.unobserve(e.target);
});
const fitted = (el) => (fit.observe(el), el);

const attesting = new Map(); // task id → { item, note }: the Done when item being attested and the reason typed so far

function doneItem(t, d, i) {
  const ok = d.status === "proven";
  // The same rule as the server and the Mac app: a person can attest while it's building or in review.
  const canAttest = !ok && (t.state === "building" || t.state === "reviewing");
  const open = canAttest && attesting.get(t.id)?.item === i;
  return h("div", { class: "check" },
    h("span", { class: `mark ${ok ? "ok" : d.status === "failed" ? "bad" : "wait"}` }, ok ? "✓" : d.status === "failed" ? "✕" : "○"),
    h("div", { style: "flex:1;min-width:0" },
      h("div", { class: "check-head" }, h("span", { class: "check-text" }, d.text),
        ok && h("span", { class: "pill" }, d.evidence?.attested ? "Attested" : "Proven"),
        canAttest && !open && h("button", { class: "btn small", onclick: () => { attesting.set(t.id, { item: i, note: "" }); render(); document.querySelector(`[data-keep="${t.id}:attest"]`)?.focus(); } }, "Attest")),
      open && attestForm(t, i),
      d.evidence && h("div", { class: "muted", style: "font-size:13.5px" }, d.evidence.attested ? `Attested by @${d.evidence.by}${d.evidence.reason ? ` — ${d.evidence.reason}` : ""}` : d.evidence.summary),
      d.evidence?.output?.length > 0 && h("pre", { class: "out" }, [d.evidence.command && `$ ${d.evidence.command}`, ...d.evidence.output].filter(Boolean).join("\n")),
      d.evidence?.file && proofFile(d.evidence)));
}

/** Attest to a Done when item yourself, with an optional reason. */
function attestForm(t, i) {
  const close = () => { attesting.delete(t.id); render(); };
  const go = () => {
    const note = (attesting.get(t.id)?.note ?? "").trim();
    if (!send({ type: "task.checkedIt", id: t.id, item: i, note: note || null })) return;
    close();
  };
  return h("form", { class: "attest", onsubmit: (e) => { e.preventDefault(); go(); } },
    h("b", {}, "Attest to this yourself"),
    h("input", { type: "text", "data-keep": `${t.id}:attest`, placeholder: "Reason (optional)", value: attesting.get(t.id)?.note ?? "",
      oninput: (e) => { const a = attesting.get(t.id); if (a) a.note = e.target.value; }, onkeydown: (e) => { if (e.key === "Escape") close(); } }),
    h("div", { class: "row", style: "gap:6px;justify-content:flex-end" },
      h("button", { class: "btn small", type: "button", onclick: close }, "Cancel"),
      h("button", { class: "btn small primary", type: "submit" }, "Attest")));
}

/** `/attachments/<uuid>/<name>`, the shape the server keeps a proof's file under (attachments.ts). */
const ATTACHMENT = /^\/attachments\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/[\w.\-]{1,120}$/;

/** The screenshot or recording the runner uploaded: shown in place, or a chip to open it if it won't load. */
function proofFile(e) {
  const src = e.file;
  if (!ATTACHMENT.test(src)) return null;
  const file = src.split("/").pop();
  const chip = () => h("a", { class: "proof-file", href: src, target: "_blank", rel: "noopener noreferrer", title: `Open ${file}` }, file, h("span", { class: "muted" }, " ↗"));
  if (e.kind === "video" || /\.(mp4|mov|webm|m4v)$/i.test(file)) {
    const video = h("video", { class: "proof-video", src, controls: true, preload: "metadata", playsinline: true, "data-media": src, onerror: () => video.replaceWith(chip()) });
    return video;
  }
  const link = h("a", { class: "proof-img", href: src, target: "_blank", rel: "noopener noreferrer", title: "Open full size", "data-media": src },
    h("img", { src, alt: e.summary, loading: "lazy", onerror: () => link.replaceWith(chip()) }));
  return link;
}

function timeline(t) {
  const known = knownTasks();
  const items = [
    ...t.events.map((e) => ({ at: e.at, el: h("div", { class: "event" }, h("b", {}, name(e.who)), " ", e.text, h("span", { class: "when" }, ago(e.at))) })),
    ...t.comments.map((c) => ({ at: c.at, el: h("div", { class: "comment" }, h("div", { class: "row" }, h("b", {}, name(c.author)), c.anchor && h("span", { class: "mono muted anchor" }, c.anchor), c.via && h("span", { class: "muted" }, `via ${c.via}`), h("span", { class: "when faint" }, ago(c.at))), markdown(c.text, h, known)) })),
    ...t.changes.map((c) => ({ at: c.at, el: h("div", { class: "comment" }, h("div", { class: "row" }, h("b", {}, name(c.author)), h("span", { class: "muted" }, `asked for a change${c.anchor ? ` · ${c.anchor}` : ""} · ${c.status}`), h("span", { class: "when faint" }, ago(c.at))), markdown(c.text, h, known)) })),
  ].sort((a, b) => b.at - a.at);
  return [h("h2", {}, "Timeline"),
    compose(t, "comment", "Comment…", "Comment", (text) => send({ type: "task.comment", id: t.id, text })),
    h("div", { class: "timeline", style: "margin-top:14px" }, items.slice(0, 60).map((i) => i.el))];
}

// ---- the diff ----

// A review in progress on a task's diff, kept in memory like draftEdits: the lines picked, the comment
// being typed on them, the comments waiting to be sent, and the summary.
const reviewPicks = new Map(); // task id → { path, anchor, head }
const reviewNotes = new Map(); // task id → [{ id, rows: { first, last }, note }]
const reviewText = new Map(); // task id → the comment being typed on the picked lines
const reviewSummary = new Map(); // task id → the review's summary
let noteIds = 0;

/** The same states as decisions()'s Request change: something's working on it to send the review to. */
const reviewable = (t) => ["planning", "awaitingApproval", "building", "reviewing"].includes(t.state);
const touch = matchMedia("(pointer: coarse)");

function diffView(t) {
  const key = `${t.pr?.head ?? ""}+${t.diff?.added}-${t.diff?.removed}`;
  const cached = state.diffs.get(t.id);
  if (!cached || cached.key !== key) {
    // The diff that was showing stays up until the new one is in, and the review moves onto it.
    state.diffs.set(t.id, { key, files: cached?.files ?? null });
    fetch(`/api/tasks/${t.id}/diff`).then((r) => (r.ok ? r.text() : null)).then((text) => {
      const files = text == null ? cached?.files ?? [] : parseDiff(text);
      if (text != null && cached?.files) carryReview(t.id, cached.files, files);
      state.diffs.set(t.id, { key, files });
      render();
    });
  }
  const files = state.diffs.get(t.id).files;
  if (!files) return h("div", { class: "card empty" }, "Loading the diff…");
  if (!files.length) return h("div", { class: "card empty" }, "No diff yet.");
  const can = reviewable(t);
  const notes = reviewNotes.get(t.id) ?? [];
  return h("div", { style: "margin-top:12px" },
    can && notes.length > 0 && reviewBar(t, notes),
    can && !notes.length && h("p", { class: "muted", style: "font-size:13px;margin:0 0 10px" },
      touch.matches ? "Tap a line number to comment on it; tap another to take in the lines between." : "Click a line number to comment on it; shift-click to take in more lines."),
    files.map((f) => diffFile(t, f, can, notes.filter((n) => n.note.path === f.path))));
}

function diffFile(t, f, can, notes) {
  const sel = reviewPicks.get(t.id);
  const mine = sel?.path === f.path;
  const click = (row, e) => {
    const extending = mine && (e.shiftKey || (touch.matches && !(reviewText.get(t.id) ?? "").trim()));
    reviewPicks.set(t.id, extending ? extend(sel, f.path, row) : pick(f.path, row));
    render();
    // On a phone the keyboard would cover the lines still being picked.
    if (!touch.matches) document.querySelector(`[data-keep="${t.id}:review-comment"]`)?.focus({ preventScroll: true });
  };
  const rows = [];
  f.lines.forEach((l, row) => {
    const on = can && picked(sel, f.path, row) && pickable(l);
    const num = (n) => can && pickable(l)
      ? h("td", { class: "n pick", title: "Comment on this line", onclick: (e) => click(row, e) }, n ?? "")
      : h("td", { class: "n" }, n ?? "");
    rows.push(h("tr", { class: `${l.kind}${on ? " picked" : ""}${notes.some((n) => row >= n.rows.first && row <= n.rows.last) ? " noted" : ""}` },
      num(l.old), num(l.new), h("td", { class: "c" }, l.text)));
    for (const n of notes) if (n.rows.last === row) rows.push(h("tr", { class: "inline" }, h("td", { colspan: 3 }, pendingNote(t, n))));
    if (can && mine && rowsOf(sel).last === row) rows.push(h("tr", { class: "inline" }, h("td", { colspan: 3 }, commentBox(t, f))));
  });
  return h("div", { class: "diff" },
    h("div", { class: "file" }, h("span", {}, f.path), h("span", { class: "spacer" }),
      notes.length > 0 && h("span", { class: "muted" }, `${notes.length} comment${notes.length === 1 ? "" : "s"}`),
      h("span", { class: "ok" }, `+${f.added}`), h("span", { class: "bad" }, `−${f.removed}`)),
    h("div", { class: "scroll" }, h("table", {}, rows)));
}

/** The box under the picked lines: what to say about them. */
function commentBox(t, f) {
  const sel = reviewPicks.get(t.id);
  const lines = selected(sel, f.lines);
  const draft = toNote(f.path, lines, "");
  const close = () => { reviewPicks.delete(t.id); reviewText.delete(t.id); render(); };
  const add = () => {
    const text = (reviewText.get(t.id) ?? "").trim();
    const note = toNote(f.path, lines, text);
    if (!text || !note) return;
    const r = rowsOf(sel);
    reviewNotes.set(t.id, [...(reviewNotes.get(t.id) ?? []), { id: ++noteIds, rows: { first: r.first, last: r.last }, note }]);
    close();
  };
  return h("div", { class: "review-box" },
    h("b", {}, draft ? `Comment on ${linesLabel(draft)}` : "Pick a line to comment on"),
    h("textarea", { "data-keep": `${t.id}:review-comment`, rows: 3, placeholder: "What should change here?",
      oninput: (e) => reviewText.set(t.id, e.target.value),
      onkeydown: (e) => {
        if (e.key === "Escape") close();
        if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); add(); }
      } }, reviewText.get(t.id) ?? ""),
    h("div", { class: "row", style: "gap:6px;justify-content:flex-end" },
      h("button", { class: "btn small", onclick: close }, "Cancel"),
      h("button", { class: "btn small primary", disabled: !draft, onclick: add }, "Add comment")));
}

/** A comment waiting to go with the review. */
function pendingNote(t, n) {
  const remove = () => { reviewNotes.set(t.id, (reviewNotes.get(t.id) ?? []).filter((x) => x.id !== n.id)); render(); };
  return h("div", { class: "review-note" },
    h("div", { class: "row", style: "gap:8px" },
      h("span", { class: "pill" }, "Pending"), h("span", { class: "muted" }, linesLabel(n.note)), h("span", { class: "spacer" }),
      h("button", { class: "btn small", onclick: remove }, "Remove")),
    h("div", { class: "review-note-text" }, n.note.text));
}

/** At the top of the Diff tab while comments wait: a summary and Submit review, sent as one change request. */
function reviewBar(t, notes) {
  const submit = () => {
    const summary = (reviewSummary.get(t.id) ?? "").trim();
    if (!send({ type: "task.review", id: t.id, notes: notes.map((n) => n.note), summary: summary || null })) return;
    reviewNotes.delete(t.id);
    reviewSummary.delete(t.id);
    reviewPicks.delete(t.id);
    reviewText.delete(t.id);
    toast(`Review sent: ${notes.length} comment${notes.length === 1 ? "" : "s"}`);
    render();
  };
  const discard = () => { reviewNotes.delete(t.id); reviewSummary.delete(t.id); render(); };
  return h("div", { class: "review-bar" },
    h("div", { class: "row", style: "gap:8px" },
      h("b", {}, `Review · ${notes.length} comment${notes.length === 1 ? "" : "s"}`), h("span", { class: "spacer" }),
      h("button", { class: "btn small", onclick: discard }, "Discard"),
      h("button", { class: "btn small primary", onclick: submit }, "Submit review")),
    h("textarea", { "data-keep": `${t.id}:review-summary`, rows: 1, placeholder: "Summary (optional)",
      oninput: (e) => reviewSummary.set(t.id, e.target.value),
      onkeydown: (e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); submit(); } } }, reviewSummary.get(t.id) ?? ""));
}

/** A reloaded diff keeps the pending comments and the picked lines whose code is still there, renumbered;
 *  comments on lines that are gone are dropped. */
function carryReview(id, before, files) {
  const moved = (path, rows, note) => {
    const f = files.find((x) => x.path === path);
    const at = f && relocate(rows, note, f.lines);
    return at && { at, note: toNote(path, f.lines.slice(at.first, at.last + 1), note.text) };
  };
  const notes = reviewNotes.get(id);
  if (notes?.length) {
    const kept = notes.flatMap((n) => {
      const m = moved(n.note.path, n.rows, n.note);
      return m?.note ? [{ ...n, rows: m.at, note: m.note }] : [];
    });
    if (kept.length < notes.length) toast(`${notes.length - kept.length} pending comment${notes.length - kept.length === 1 ? " is" : "s are"} gone: those lines changed.`);
    reviewNotes.set(id, kept);
  }
  const sel = reviewPicks.get(id);
  const was = sel && before.find((x) => x.path === sel.path);
  const note = was && toNote(sel.path, selected(sel, was.lines), "");
  const m = note && moved(sel.path, rowsOf(sel), note);
  if (!m) reviewPicks.delete(id);
  else reviewPicks.set(id, { path: sel.path, anchor: sel.anchor <= sel.head ? m.at.first : m.at.last, head: sel.anchor <= sel.head ? m.at.last : m.at.first });
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

window.addEventListener("hashchange", () => {
  // Forget what was typed into notes and drafts that are left (and saved).
  const r = route();
  for (const id of noteText.keys()) if (!noteSaves.has(id) && id !== r.id) noteText.delete(id);
  for (const [id, e] of draftEdits) if (id !== r.id && e.title === state.tasks.get(id)?.title && e.brief === state.tasks.get(id)?.brief) draftEdits.delete(id);
  window.scrollTo(0, 0);
  render();
});
$("update-refresh").addEventListener("click", () => location.reload());
connect();
