// Maple Factory on the web: review on the go. The same live feed as the apps (/client/connect, signed
// in by the session cookie): the inbox, and a task's plan, mockups, diff, review and proofs, with the
// decisions a person makes on them; new tasks and drafts, and the scratchpad. Nothing here touches
// terminals or machines, except to answer an agent's permission prompt with Yes or No.
//
// Every string from the factory goes in with textContent; agents' screen mockups render in an iframe
// with an empty sandbox (no scripts, no same-origin).

import { markdown } from "./markdown.js";
import { markdownEditor } from "./editor.js";

const state = { me: null, org: "", members: [], goals: [], tasks: new Map(), notes: [], live: false, diffs: new Map(), machines: [] };
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
      $("org").textContent = m.org || "Maple Factory";
      status();
      break;
    case "task.updated":
      if (!state.tasks.has(m.task.id)) created(m.task);
      state.tasks.set(m.task.id, m.task);
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
    case "error":
      // The task being created didn't take; let the composer try again. Errors carry no request id, so
      // take one that comes back soon after the create to be about it; any later one leaves it alone.
      if (creating && Date.now() - creating.at < 5_000) createFailed();
      toast(m.message);
      break;
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
  const waiting = [...state.tasks.values()].filter(needsYou).length;
  $("inbox-count").textContent = waiting || "";
  document.title = `${waiting ? `(${waiting}) ` : ""}Maple Factory`;
  const next = { task: () => taskView(r.id), tasks: tasksView, new: () => newTaskView(r), notes: notesView, note: () => noteView(r.id) }[r.name]?.() ?? inboxView();
  // Keep what someone's typing: re-render only around the boxes being typed in.
  mount(next, !!document.activeElement?.closest?.("[data-keep]"));
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
  const active = [...state.tasks.values()].filter((t) => !["drafting", "merged", "cancelled"].includes(t.state) && !isQueued(t)).sort((a, b) => b.updatedAt - a.updatedAt);
  const done = [...state.tasks.values()].filter((t) => t.state === "merged").sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 10);
  return h("div", {},
    h("h1", {}, "Tasks"),
    drafts.length > 0 && [h("h2", {}, `Drafts · ${drafts.length}`), h("div", { class: "list" }, drafts.map((t) => row(t, t.owner === state.me?.login ? `draft · edited ${ago(t.updatedAt)}` : `${name(t.owner)}'s draft`)))],
    queued.length > 0 && [h("h2", {}, `Queued · ${queued.length}`), h("div", { class: "list" }, queued.map((t, i) => row(t, `#${i + 1} · ${queueLine(t)}`)))],
    h("h2", {}, `In flight · ${active.length}`),
    active.length ? h("div", { class: "list" }, active.map((t) => row(t, t.waiting || STATE_TITLE[t.state]))) : h("div", { class: "card empty" }, "Nothing in flight."),
    done.length > 0 && [h("h2", {}, "Recently merged"), h("div", { class: "list" }, done.map((t) => row(t, `merged ${ago(t.updatedAt)}`)))]);
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
  const brief = markdownEditor({ value: composer.brief, rows: 10, keep: "new:brief", placeholder: "The brief: what you want and why, what done looks like.", oninput: (e) => (composer.brief = e.target.value) }, h);
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
  const body = markdownEditor({ value: text.body, placeholder: "Jot it down…", minHeight: "50vh", oninput: edit("body"), onblur: () => noteSaves.has(id) && saveNote(id, true) }, h);
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
}

// ---- a task ----

const taskTabs = new Map(); // id → "overview" | "diff"

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
    promptCard(t),
    t.hand && handCard(t),
    t.question && !t.hand && questionCard(t),
    t.state === "drafting" && t.owner === state.me?.login ? draftEditor(t) : decisions(t),
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
    h("b", {}, `${name(t.worker.role)} is waiting on you`),
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
    // A failed merge's hand carries the ways forward instead.
    if (passed && t.reviews.length >= t.reviewsNeeded && t.hand?.reason !== "mergeFailed") {
      buttons.push(h("button", { class: "btn go", disabled: failing || pending, onclick: () => send({ type: "task.merge", id: t.id }) },
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
    // Waiting on its plan's approval, nothing is running to retry; requesting a change plans again.
    if (t.state !== "drafting" && t.state !== "awaitingApproval") buttons.push(h("button", { class: "btn", onclick: () => send({ type: "task.retry", id: t.id }) }, "Retry"));
    if (t.state !== "cancelled") buttons.push(h("button", { class: "btn danger", onclick: () => { cancelling.add(t.id); render(); } }, "Cancel…"));
  }
  const steerable = ["planning", "awaitingApproval", "building", "reviewing"].includes(t.state);
  const [placeholder, label] = {
    awaitingApproval: ["Ask for a change to the plan…", "Request change"],
    reviewing: ["What should change before it merges? The builder picks it up.", "Request changes"],
  }[t.state] ?? ["Steer it: what should change?", "Request change"];
  return h("div", {},
    buttons.length > 0 && h("div", { class: "actions" }, buttons),
    cancelling.has(t.id) && t.state !== "cancelled" && t.state !== "merged" && cancelCard(t),
    steerable && compose(t, "steer", placeholder, label, (text) => send({ type: "task.steer", id: t.id, text })));
}

const cancelling = new Set(); // ids whose Cancel… is asking "are you sure?"

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
    submit(text);
    editor.clear();
  };
  const editor = markdownEditor({ placeholder, rows: 2, onsubmit: go }, h);
  return h("div", { class: "compose", "data-keep": `${t.id}:${key}` }, editor, h("div", {}, h("button", { class: "btn small", onclick: go }, label)));
}

// What's typed into a draft's editor, until it's saved.
const draftEdits = new Map(); // id → { title, brief }

function draftEditor(t) {
  const edits = draftEdits.get(t.id) ?? { title: t.title, brief: t.brief };
  draftEdits.set(t.id, edits);
  const dirty = () => edits.title.trim() !== t.title || edits.brief !== t.brief;
  const title = h("input", { type: "text", placeholder: "Title", value: edits.title, oninput: (e) => { edits.title = e.target.value; mark(); } });
  const brief = markdownEditor({ value: edits.brief, rows: 8, placeholder: "The brief: what you want and why, what done looks like.", oninput: (e) => { edits.brief = e.target.value; mark(); } }, h);
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
      h("button", { class: "btn plan", onclick: plan }, "Send to planning")));
}

function overview(t) {
  const editing = t.state === "drafting" && t.owner === state.me?.login;
  return h("div", {},
    t.brief && !editing && [h("h2", {}, "Brief"), h("div", { class: "card" }, markdown(t.brief, h))],
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
      d.evidence && h("div", { class: "muted", style: "font-size:13.5px" }, d.evidence.attested ? `Attested by @${d.evidence.by}${d.evidence.reason ? ` — ${d.evidence.reason}` : ""}` : d.evidence.summary),
      d.evidence?.output?.length > 0 && h("pre", { class: "out" }, [d.evidence.command && `$ ${d.evidence.command}`, ...d.evidence.output].filter(Boolean).join("\n")),
      d.evidence?.file && proofFile(d.evidence)));
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
  const items = [
    ...t.events.map((e) => ({ at: e.at, el: h("div", { class: "event" }, h("b", {}, name(e.who)), " ", e.text, h("span", { class: "when" }, ago(e.at))) })),
    ...t.comments.map((c) => ({ at: c.at, el: h("div", { class: "comment" }, h("div", { class: "row" }, h("b", {}, name(c.author)), c.via && h("span", { class: "muted" }, `via ${c.via}`), h("span", { class: "when faint" }, ago(c.at))), markdown(c.text, h)) })),
    ...t.changes.map((c) => ({ at: c.at, el: h("div", { class: "comment" }, h("div", { class: "row" }, h("b", {}, name(c.author)), h("span", { class: "muted" }, `asked for a change · ${c.status}`), h("span", { class: "when faint" }, ago(c.at))), markdown(c.text, h)) })),
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

window.addEventListener("hashchange", () => {
  // Forget what was typed into notes and drafts that are left (and saved).
  const r = route();
  for (const id of noteText.keys()) if (!noteSaves.has(id) && id !== r.id) noteText.delete(id);
  for (const [id, e] of draftEdits) if (id !== r.id && e.title === state.tasks.get(id)?.title && e.brief === state.tasks.get(id)?.brief) draftEdits.delete(id);
  window.scrollTo(0, 0);
  render();
});
connect();
