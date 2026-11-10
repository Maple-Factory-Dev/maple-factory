// The #/memory page (MF-394): what the factory's agents remember between tasks (MF-391), filtered by kind,
// status, scope (`?scope=org|repo:owner/name|goal:<id>`) and the task it was learned on (`?task=MF-391`).
// Each row says where it came from and how often it's been used; people edit its text, kind and tags,
// archive or restore it, and accept a proposed one. The server owns memories: every change goes out as
// memory.edit / memory.status and comes back as memory.updated.

export const KINDS = [["", "All"], ["fact", "Fact"], ["convention", "Convention"], ["gotcha", "Gotcha"], ["preference", "Preference"]];
export const STATUSES = [["active", "Active"], ["proposed", "Proposed"], ["archived", "Archived"]];
/** An active memory not given to an agent (or made) in this long is marked Stale. */
export const STALE_MS = 90 * 86_400_000;

/** `org`, `repo:owner/name` or `goal:<id>` for a memory's scope. */
export const scopeKey = (s) => (s?.kind === "org" || !s?.key ? "org" : `${s.kind}:${s.key}`);

export const isStale = (m, now = Date.now()) => m.status === "active" && now - (m.lastUsedAt ?? m.createdAt) > STALE_MS;

/** Memories to list, most recently changed first. */
export function filterMemories(memories, { kind = "", status = "active", scope = "", task = "" } = {}) {
  return [...(memories ?? [])]
    .filter((m) => (!kind || m.kind === kind) && (!status || m.status === status) && (!scope || scopeKey(m.scope) === scope) && (!task || m.source?.task === task))
    .sort((a, b) => b.updatedAt - a.updatedAt);
}

/** "Edit text" → tags: lowercase, unique, at most 8. */
export const parseTags = (text) => [...new Set(text.split(/[,\s]+/).map((t) => t.trim().toLowerCase()).filter(Boolean))].slice(0, 8);

export function createMemory({ state, h, send, icon, ago, render = null }) {
  let editing = null; // { id, text, kind, tags } while a row's editor is open

  // A redraw in place (the hashchange nudge scrolls to the top); render is optional.
  const redraw = () => (render ? render() : window.dispatchEvent(new HashChangeEvent("hashchange")));

  function view(r) {
    const params = new URLSearchParams(r.query);
    const kind = params.get("kind") || "";
    const status = params.get("status") || "active";
    const scope = params.get("scope") || "";
    const task = params.get("task") || "";
    const href = (p) => {
      const q = new URLSearchParams(Object.entries({ scope, kind, status, task, ...p }).filter(([k, v]) => v && !(k === "status" && v === "active")));
      return `#/memory${q.size ? `?${q}` : ""}`;
    };
    const all = state.memories ?? [];
    const list = filterMemories(all, { kind, status, scope, task });
    const count = (s) => filterMemories(all, { kind, status: s, scope, task }).length;
    const repos = [...new Set([...(state.repos ?? []).map((x) => x.name), ...all.filter((m) => m.scope.kind === "repo").map((m) => m.scope.key)])].sort();
    return h("div", { class: "memory-page", "data-testid": "memory-page" },
      h("h1", {}, task ? `Memory · ${task}` : "Memory"),
      h("p", { class: "muted" }, "What the factory's agents remember between tasks. They're given the active ones that apply to their work."),
      h("div", { class: "row memory-filters" },
        h("div", { class: "chips", role: "tablist", "aria-label": "Kind" }, KINDS.map(([key, label]) =>
          h("a", { class: `chip${kind === key ? " on" : ""}`, href: href({ kind: key }), "data-kind": key || "all", role: "tab", "aria-selected": String(kind === key) }, label))),
        h("div", { class: "chips", role: "tablist", "aria-label": "Status" }, STATUSES.map(([key, label]) =>
          h("a", { class: `chip${status === key ? " on" : ""}`, href: href({ status: key }), "data-status": key, role: "tab", "aria-selected": String(status === key) },
            label, h("span", { class: "chip-count" }, ` ${count(key)}`)))),
        h("select", { "aria-label": "Scope", "data-testid": "memory-scope", onchange: (e) => (location.hash = href({ scope: e.target.value })) },
          h("option", { value: "", selected: !scope }, "Everywhere"),
          h("option", { value: "org", selected: scope === "org" }, "The whole org"),
          repos.length ? h("optgroup", { label: "Repos" }, repos.map((n) => h("option", { value: `repo:${n}`, selected: scope === `repo:${n}` }, n))) : null,
          state.goals.length ? h("optgroup", { label: "Goals" }, state.goals.map((g) => h("option", { value: `goal:${g.id}`, selected: scope === `goal:${g.id}` }, g.name))) : null),
        task ? h("a", { class: "chip on", href: href({ task: "" }), "data-testid": "memory-task-filter", title: "Show every task's" }, `Learned on ${task} `, icon("x", { size: 12 })) : null),
      list.length
        ? h("div", { class: "list" }, list.map(rowView))
        : h("div", { class: "card empty" }, icon("lightbulb", { size: 28 }), all.length ? "No memories match." : "Nothing remembered yet. Agents add memories with remember as they work."));
  }

  function scopeLabel(s) {
    if (s.kind === "repo") return s.key;
    if (s.kind === "goal") return state.goals.find((g) => g.id === s.key)?.name ?? "A goal";
    return "Whole org";
  }

  /** "MF-391 builder on mbp-14 · for afomera · used 12×, 3d ago", the task linking to its page. */
  function provenance(m) {
    const s = m.source ?? {};
    const who = s.task
      ? [h("a", { href: `#/t/${s.task}`, "data-testid": "memory-task-link", class: "mono" }, s.task), s.role ? ` ${s.role}` : "", s.machine ? ` on ${s.machine}` : "", ` · for ${s.by}`]
      : s.agent ? [s.agent, ` · for ${s.by}`] : [`by ${s.by}`];
    const used = m.uses ? `used ${m.uses}×${m.lastUsedAt ? `, ${ago(m.lastUsedAt)}` : ""}` : "never used";
    return h("div", { class: "sub memory-source" }, ...who, ` · ${used} · added ${ago(m.createdAt)}`);
  }

  function rowView(m) {
    if (editing?.id === m.id) return editorView(m);
    const archived = m.status === "archived";
    return h("div", { class: `item memory-row${archived ? " archived" : ""}`, "data-testid": "memory-row", "data-memory": m.id },
      h("div", { class: "memory-body" },
        h("div", { class: "memory-title" },
          h("span", { class: `pill memory-kind kind-${m.kind}` }, m.kind),
          m.status === "proposed" ? h("span", { class: "pill memory-proposed" }, "Proposed") : null,
          isStale(m) ? h("span", { class: "pill memory-stale", "data-testid": "memory-stale", title: "Not given to an agent in 90 days" }, "Stale") : null,
          h("span", { class: "memory-scope muted" }, scopeLabel(m.scope))),
        h("div", { class: "memory-text", "data-testid": "memory-text" }, m.text),
        m.tags.length ? h("div", { class: "memory-tags" }, m.tags.map((t) => h("span", { class: "tag" }, `#${t}`))) : null,
        provenance(m)),
      h("div", { class: "memory-actions" },
        m.status === "proposed" ? h("button", { type: "button", class: "btn small primary", "data-testid": "memory-accept", onclick: () => send({ type: "memory.status", id: m.id, status: "active" }) }, "Accept") : null,
        h("button", { type: "button", class: "btn small", "data-testid": "memory-edit", onclick: () => { editing = { id: m.id, text: m.text, kind: m.kind, tags: m.tags.join(", ") }; redraw(); } }, "Edit"),
        archived
          ? h("button", { type: "button", class: "btn small", "data-testid": "memory-restore", onclick: () => send({ type: "memory.status", id: m.id, status: "active" }) }, "Restore")
          : h("button", { type: "button", class: "btn small danger-text", "data-testid": "memory-archive", onclick: () => send({ type: "memory.status", id: m.id, status: "archived" }) }, m.status === "proposed" ? "Dismiss" : "Archive")));
  }

  function editorView(m) {
    const save = () => {
      const text = editing.text.trim();
      if (!text) return;
      if (send({ type: "memory.edit", id: m.id, text, kind: editing.kind, tags: parseTags(editing.tags) })) { editing = null; redraw(); }
    };
    return h("div", { class: "item memory-row editing", "data-testid": "memory-row", "data-memory": m.id, "data-keep": `memory-${m.id}` },
      h("div", { class: "memory-body memory-editor" },
        h("textarea", { rows: 3, maxlength: 600, "aria-label": "Text", "data-testid": "memory-edit-text", oninput: (e) => (editing.text = e.target.value) }, editing.text),
        h("div", { class: "row", style: "gap:8px;flex-wrap:wrap" },
          h("select", { "aria-label": "Kind", "data-testid": "memory-edit-kind", onchange: (e) => (editing.kind = e.target.value) },
            KINDS.slice(1).map(([k, label]) => h("option", { value: k, selected: k === editing.kind }, label))),
          h("input", { type: "text", "aria-label": "Tags", placeholder: "tags, comma separated", value: editing.tags, "data-testid": "memory-edit-tags", autocapitalize: "off", spellcheck: "false",
            style: "flex:1;min-width:160px", oninput: (e) => (editing.tags = e.target.value), onkeydown: (e) => { if (e.key === "Enter") save(); } }),
          h("button", { type: "button", class: "btn small primary", "data-testid": "memory-save", onclick: save }, "Save"),
          h("button", { type: "button", class: "btn small", onclick: () => { editing = null; redraw(); } }, "Cancel"))));
  }

  /** memory.updated / memory.removed into state.memories; whether it was one. */
  function receive(m) {
    if (m.type === "snapshot") { state.memories = m.memories ?? []; return false; }
    if (m.type === "memory.updated") { state.memories = [...(state.memories ?? []).filter((x) => x.id !== m.memory.id), m.memory]; return true; }
    if (m.type === "memory.removed") { state.memories = (state.memories ?? []).filter((x) => x.id !== m.id); if (editing?.id === m.id) editing = null; return true; }
    return false;
  }

  return { view, receive };
}
