// Shared planning docs in the web app (MF-361, docs/planning-docs.md): the #/docs list (all, or one goal's,
// with archived ones on a toggle) and the #/docs/<id> page, which lazy-loads the vendored TipTap + Yjs editor
// (./docs/editor.bundle.js) so the rest of /app never downloads it.

export const DOC_ROUTE = /^\/docs\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/;

/** Keeps state.docs current from the feed. Returns true when it handled the message. */
export function receiveDocs(state, m) {
  if (m.type === "snapshot") { state.docs = m.docs ?? []; state.decisions = m.decisions ?? []; }
  else if (m.type === "decision.updated") state.decisions = [...(state.decisions ?? []).filter((d) => d.id !== m.decision.id), m.decision];
  else if (m.type === "decision.log") (state.decisionLogs ??= {})[m.id] = m.events;
  else if (m.type === "doc.updated") state.docs = [...(state.docs ?? []).filter((d) => d.id !== m.doc.id), m.doc];
  else if (m.type === "doc.removed") state.docs = (state.docs ?? []).filter((d) => d.id !== m.id);
  else if (m.type === "doc.threads") (state.docThreads ??= {})[m.doc] = m.threads;
  else if (m.type === "doc.thread.updated") {
    const list = (state.docThreads ??= {})[m.thread.doc] ?? [];
    state.docThreads[m.thread.doc] = [...list.filter((t) => t.id !== m.thread.id), m.thread];
  } else return false;
  return true;
}

/** Docs to list: not archived (unless `archived`), in `goal` if given, newest edit first. */
export function listDocs(docs, { goal = null, archived = false } = {}) {
  return [...(docs ?? [])]
    .filter((d) => (archived ? d.archived : !d.archived) && (!goal || d.goal === goal))
    .sort((a, b) => b.updatedAt - a.updatedAt);
}

export function createDocs({ state, h, send, render, toast, icon, ago, allTasks }) {
  let pendingCreate = null; // the title of a doc.create we sent, to open it when its doc.updated lands
  let open = null; // { id, host, handle, status, peers, error }
  let lastDecision = null; // the ?decision= last scrolled to, so a re-render doesn't scroll again

  const memberOf = (login) => state.members.find((m) => m.login === login);
  const goalName = (id) => state.goals.find((g) => g.id === id)?.name;

  /** The editor's view of a task: what task embeds draw (MF-363). */
  const taskView = (t) => ({ id: t.id, title: t.title, state: t.state, pr: t.pr ? { number: t.pr.number, url: t.pr.url ?? null, state: t.pr.state } : null, assignee: t.owner ?? null, goal: t.goal });

  /** Called (by app.js) after a task.updated or snapshot is applied: open task embeds redraw. */
  function tasksChanged() {
    open?.handle?.tasksChanged();
  }

  function receive(m) {
    if (!receiveDocs(state, m)) {
      // Reconnected: ask again for the open doc's threads.
      if (m.type === "snapshot" && open) send({ type: "doc.threads", doc: open.id });
      return false;
    }
    if (m.type === "decision.updated" || m.type === "snapshot") open?.handle?.decisionsChanged?.();
    if (m.type === "doc.threads" || m.type === "doc.thread.updated") {
      if (open?.id === (m.doc ?? m.thread.doc)) open.handle?.threadsChanged();
      return "quiet"; // no full render: the editor redraws its own rail
    }
    if (m.type === "doc.updated" && pendingCreate && m.doc.createdBy === state.me?.login && m.doc.title === pendingCreate) {
      pendingCreate = null;
      location.hash = `#/docs/${m.doc.id}`;
    }
    if (open && m.type === "doc.updated" && m.doc.id === open.id) {
      // Archived elsewhere: the server closes the socket; stop editing here too.
      open.handle?.setEditable(!m.doc.archived);
    }
    return true;
  }

  function create(goal) {
    const title = `Untitled doc ${new Date().toLocaleDateString(undefined, { month: "short", day: "numeric" })}, ${new Date().toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}`;
    pendingCreate = title;
    if (!send({ type: "doc.create", title, ...(goal ? { goal } : {}) })) { pendingCreate = null; toast("Not connected; try again in a moment."); }
  }

  function listView(r) {
    const params = new URLSearchParams(r.query);
    const goal = params.get("goal");
    const archived = params.get("archived") === "1";
    const docs = listDocs(state.docs, { goal, archived });
    const href = (p) => `#/docs${new URLSearchParams(Object.entries(p).filter(([, v]) => v)).size ? `?${new URLSearchParams(Object.entries(p).filter(([, v]) => v))}` : ""}`;
    return h("div", { class: "docs-page" },
      h("div", { class: "row" }, h("h1", { style: "flex:1" }, goal ? `Docs · ${goalName(goal) ?? goal}` : "Docs"),
        h("button", { class: "btn", "data-new-doc": "", onclick: () => create(goal) }, "New doc")),
      h("p", { class: "muted" }, "Shared planning and research docs every member can edit together."),
      h("div", { class: "row docs-filters" },
        h("select", { "aria-label": "Goal", onchange: (e) => (location.hash = href({ goal: e.target.value, archived: archived ? "1" : "" })) },
          h("option", { value: "", selected: !goal }, "All goals"),
          state.goals.map((g) => h("option", { value: g.id, selected: g.id === goal }, g.name))),
        h("label", { class: "muted" }, h("input", { type: "checkbox", checked: archived, onchange: (e) => (location.hash = href({ goal, archived: e.target.checked ? "1" : "" })) }), " Archived")),
      docs.length
        ? h("div", { class: "list" }, docs.map((d) => h("a", { class: "item doc", href: `#/docs/${d.id}`, "data-doc": d.id },
            h("span", { class: "nav-icon" }, icon("file-text", { size: 16 })),
            h("div", { style: "flex:1;min-width:0" },
              h("div", { class: "title" }, d.title || "Untitled doc"),
              h("div", { class: "sub" }, d.goal ? `${goalName(d.goal) ?? d.goal} · ` : "", `edited ${ago(d.updatedAt)} · by ${memberOf(d.createdBy)?.name || d.createdBy}`)),
            d.openThreads ? h("span", { class: "pill tag doc-threads-count", title: `${d.openThreads} open comment thread${d.openThreads === 1 ? "" : "s"}` }, icon("message-square", { size: 12 }), ` ${d.openThreads}`) : null,
            d.archived && h("span", { class: "pill tag" }, "archived"))))
        : h("div", { class: "card empty" }, icon("file-text", { size: 28 }), archived ? "No archived docs." : "No docs yet."));
  }

  function mountEditor(id, host) {
    open = { id, host, handle: null, status: "connecting", peers: [], error: null };
    const me = memberOf(state.me.login) ?? state.me;
    import("./docs/editor.bundle.js").then(({ createDocEditor }) => {
      if (open?.id !== id) return;
      open.handle = createDocEditor({
        el: host,
        docId: id,
        me: { login: me.login, name: me.name, avatar: me.avatarUrl },
        members: () => state.members.map((m) => ({ login: m.login, name: m.name, avatar: m.avatarUrl })),
        tasks: () => allTasks().map(taskView),
        // Comments (MF-364): threads from the feed; commands go straight to the socket.
        threads: () => state.docThreads?.[id] ?? [],
        sendThreadCommand: (cmd) => { if (!send(cmd)) toast("Not connected; try again in a moment."); },
        // Decisions (MF-367): from the feed; propose / edit / accept / reject go straight to the socket.
        decisions: () => (state.decisions ?? []).filter((d) => d.doc === id),
        sendDecisionCommand: (cmd) => { if (!send(cmd)) toast("Not connected; try again in a moment."); },
        onEvent: (name, data) => {
          if (open?.id !== id) return;
          if (name === "status") open.status = data.status;
          if (name === "peers") open.peers = data;
          if (name === "error") open.error = data.message;
          if (name === "openTask") location.hash = `#/t/${data.id}`;
          if (name === "synced") showDecisionSoon();
          if (name === "status" || name === "peers" || name === "error") drawChrome();
        },
      });
      window.__mapleDoc = open.handle; // for poking at it from devtools
      send({ type: "doc.threads", doc: id });
    }, (e) => { open.error = `Couldn't load the editor: ${e.message}`; drawChrome(); });
  }

  /** `#/docs/<id>?decision=<d>`: scroll to that decision's card and flash it, once the editor has it. */
  let wantDecision = null;
  function showDecisionSoon(tries = 20) {
    if (!wantDecision || !open?.handle) return;
    if (open.handle.showDecision(wantDecision)) { wantDecision = null; return; }
    if (tries > 0) setTimeout(() => showDecisionSoon(tries - 1), 150);
  }
  function focusDecision(id) {
    if (!id) return;
    wantDecision = id;
    setTimeout(() => showDecisionSoon(), 0);
  }

  /** Redraws only the header bits (presence, status) so typing isn't disturbed by a full render. */
  function drawChrome() {
    const slot = document.querySelector("[data-doc-chrome]");
    if (slot && open) slot.replaceChildren(chrome());
  }

  function chrome() {
    const peers = open?.peers ?? [];
    return h("span", { class: "doc-chrome" },
      h("span", { class: "doc-peers", "aria-label": `${peers.length} here` }, peers.map((p) =>
        h("span", { class: "doc-peer", title: `${p.name} (@${p.login})`, style: `--peer:${p.color}` },
          p.avatar ? h("img", { src: p.avatar, alt: p.name }) : (p.name || p.login).slice(0, 1).toUpperCase()))),
      h("span", { class: `doc-status ${open?.status ?? ""}` }, open?.error ? open.error : open?.status === "connected" ? "Live" : open?.status === "disconnected" ? "Reconnecting…" : "Connecting…"));
  }

  function close() {
    open?.handle?.destroy();
    open = null;
  }

  function docView(id, decision = null) {
    if (decision && decision !== lastDecision) focusDecision(decision);
    lastDecision = decision;
    const doc = (state.docs ?? []).find((d) => d.id === id);
    if (!doc) { if (open?.id === id) close(); return h("div", {}, h("div", { class: "row muted" }, h("a", { href: "#/docs" }, "← Docs")), h("div", { class: "card empty" }, "No such doc.")); }
    if (doc.archived && open?.id === id) close();
    if (open && open.id !== id) close();
    let host = open?.id === id ? open.host : null;
    if (!host && !doc.archived) {
      host = h("div", { class: "doc-host", "data-media": `doc-editor:${id}` });
      mountEditor(id, host);
    }
    const rename = (e) => {
      const title = e.target.value.trim();
      if (title && title !== doc.title) send({ type: "doc.rename", id, title });
    };
    return h("div", { class: "doc-page" },
      h("div", { class: "row muted" },
        h("a", { href: doc.goal ? `#/docs?goal=${doc.goal}` : "#/docs" }, `← ${doc.goal ? `${goalName(doc.goal) ?? "Goal"} docs` : "Docs"}`),
        h("span", { class: "spacer" }),
        h("span", { "data-doc-chrome": "" }, chrome()),
        !doc.archived && h("button", { class: "btn ghost", "data-export": "", onclick: () => exportMd(doc) }, "Export Markdown"),
        h("button", { class: "btn ghost", "data-archive": "", onclick: () => send({ type: "doc.archive", id, archived: !doc.archived }) }, doc.archived ? "Unarchive" : "Archive")),
      h("input", { class: "doc-title", "data-keep": `doc-title:${id}`, value: doc.title, placeholder: "Untitled doc", "aria-label": "Title", readonly: !!doc.archived,
        onkeydown: (e) => { if (e.key === "Enter") { e.preventDefault(); e.target.blur(); } }, onchange: rename }),
      h("div", { class: "sub muted" }, doc.goal ? `${goalName(doc.goal) ?? doc.goal} · ` : "", `Created by ${memberOf(doc.createdBy)?.name || doc.createdBy} · edited ${ago(doc.updatedAt)}`),
      doc.archived
        ? h("div", { class: "card empty", "data-archived": "" }, "This doc is archived and read-only. Unarchive it to edit.")
        // Building this tree must not pull a live editor out of the page: a placeholder stands in, and patch() keeps it.
        : host?.isConnected ? h("div", { "data-doc-slot": id }) : host);
  }

  /**
   * Updates the open doc page in place around the editor host, so a feed message never detaches the
   * contenteditable (that blurs it and drops its selection). Returns false when a full mount is needed.
   */
  function patch(main, next) {
    const slot = next.querySelector("[data-doc-slot]");
    if (!slot) return false;
    const host = open?.host;
    const page = main.firstElementChild;
    if (!host || host.parentNode !== page || slot.parentNode !== next) { if (host) slot.replaceWith(host); return false; }
    const active = document.activeElement;
    const keepTitle = active?.classList?.contains("doc-title") && page.contains(active) ? active : null;
    for (const el of [...page.children]) if (el !== host && el !== keepTitle) el.remove();
    // Neither the host nor a title being typed in moves: everything else goes in around them, in order.
    const anchors = [keepTitle, host].filter(Boolean);
    let i = 0;
    for (const el of [...next.children]) {
      const at = el === slot ? host : keepTitle && el.classList.contains("doc-title") ? keepTitle : null;
      if (at) { i = anchors.indexOf(at) + 1; continue; }
      anchors[i] ? page.insertBefore(el, anchors[i]) : page.append(el);
    }
    page.className = next.className;
    return true;
  }

  /** "N docs" next to a goal's name, opening the goal's docs (or a new one's place when there are none). */
  function goalLink(goal) {
    const n = listDocs(state.docs, { goal }).length;
    return h("a", { class: "muted", href: `#/docs?goal=${goal}`, "data-goal-docs": goal }, n === 1 ? "1 doc" : n ? `${n} docs` : "Docs");
  }

  function exportMd(doc) {
    const md = open?.handle?.exportMarkdown();
    if (md == null) return toast("The editor hasn't loaded yet.");
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([md], { type: "text/markdown" }));
    a.download = `${(doc.title || "Untitled doc").replace(/[\\/:*?"<>|]+/g, "-")}.md`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  return { receive, tasksChanged, listView, docView, close, patch, goalLink, isOpen: () => !!open };
}
