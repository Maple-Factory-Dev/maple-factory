// The #/decisions page (MF-367, docs/planning-docs.md): every doc decision in the org, filtered by status
// (Open, Accepted, Rejected, Superseded, All), person (proposed or decided by) and goal (`?goal=`). Each row
// links back to its card in the doc (#/docs/<doc>?decision=<id>), and History asks for its append-only log.

export const STATUSES = [["open", "Open"], ["accepted", "Accepted"], ["rejected", "Rejected"], ["superseded", "Superseded"], ["all", "All"]];

/** Decisions to list, newest change first. */
export function filterDecisions(decisions, { status = "open", person = null, goal = null } = {}) {
  const want = status === "open" ? "proposed" : status;
  return [...(decisions ?? [])]
    .filter((d) => (status === "all" || d.status === want) && (!person || d.proposedBy === person || d.decidedBy === person) && (!goal || d.goal === goal))
    .sort((a, b) => (b.decidedAt ?? b.proposedAt) - (a.decidedAt ?? a.proposedAt));
}

export function createDecisions({ state, h, send, icon, ago }) {
  const opened = new Set(); // rows whose History is showing

  function view(r) {
    const params = new URLSearchParams(r.query);
    const status = params.get("status") || "open";
    const person = params.get("person") || null;
    const goal = params.get("goal") || null;
    const href = (p) => {
      const q = new URLSearchParams(Object.entries({ status, person, goal, ...p }).filter(([k, v]) => v && !(k === "status" && v === "open")));
      return `#/decisions${q.size ? `?${q}` : ""}`;
    };
    const all = state.decisions ?? [];
    const list = filterDecisions(all, { status, person, goal });
    const docTitle = (id) => (state.docs ?? []).find((d) => d.id === id)?.title || "Untitled doc";
    const goalName = (id) => state.goals.find((g) => g.id === id)?.name ?? id;
    const people = [...new Set(all.flatMap((d) => [d.proposedBy, d.decidedBy]).filter(Boolean))].sort();
    const count = (s) => filterDecisions(all, { status: s, person, goal }).length;
    return h("div", { class: "decisions-page" },
      h("h1", {}, goal ? `Decisions · ${goalName(goal)}` : "Decisions"),
      h("p", { class: "muted" }, "Who decided what, when and why, across every doc. Propose one in a doc with /decision."),
      h("div", { class: "row decisions-filters" },
        h("div", { class: "chips", role: "tablist" }, STATUSES.map(([key, label]) =>
          h("a", { class: `chip${status === key ? " on" : ""}`, href: href({ status: key }), "data-status-filter": key, role: "tab", "aria-selected": String(status === key) },
            label, key !== "all" ? h("span", { class: "chip-count" }, ` ${count(key)}`) : null))),
        h("select", { "aria-label": "Person", "data-person-filter": "", onchange: (e) => (location.hash = href({ person: e.target.value })) },
          h("option", { value: "", selected: !person }, "Anyone"),
          people.map((p) => h("option", { value: p, selected: p === person }, `@${p}`))),
        h("select", { "aria-label": "Goal", "data-goal-filter": "", onchange: (e) => (location.hash = href({ goal: e.target.value })) },
          h("option", { value: "", selected: !goal }, "All goals"),
          state.goals.map((g) => h("option", { value: g.id, selected: g.id === goal }, g.name)))),
      list.length
        ? h("div", { class: "list" }, list.map((d) => rowView(d, docTitle, goalName)))
        : h("div", { class: "card empty" }, icon("scale", { size: 28 }), status === "open" ? "No open decisions." : "No decisions match."));
  }

  /** MF-368: the tasks made from an accepted decision, live from the feed, with each one's state. */
  function madeFrom(d) {
    const made = [...(state.tasks?.values?.() ?? [])].filter((t) => t.fromDoc?.decision === d.id);
    return made.length ? h("div", { class: "sub decision-tasks", "data-decision-tasks": d.id }, "Tasks: ",
      made.map((t, i) => h("span", {}, i ? ", " : "", h("a", { href: `#/t/${t.id}` }, t.id), " ", h("span", { class: `pill state-${t.state}` }, t.state)))) : null;
  }

  function rowView(d, docTitle, goalName) {
    const chosen = d.options.find((o) => o.id === d.chosen)?.label;
    const who = d.status === "proposed"
      ? `proposed by @${d.proposedBy}${d.agent ? ` (${d.agent})` : ""} ${ago(d.proposedAt)}`
      : `${d.status === "rejected" ? "rejected" : "accepted"} by @${d.decidedBy} ${ago(d.decidedAt)}`;
    // A superseded row says so and links to the decision that replaced it.
    const replacement = d.supersededBy ? (state.decisions ?? []).find((x) => x.id === d.supersededBy) : null;
    const showing = opened.has(d.id);
    const log = state.decisionLogs?.[d.id];
    return h("div", { class: "item decision-row", "data-decision-row": d.id },
      h("a", { class: "decision-link", href: `#/docs/${d.doc}?decision=${d.id}` },
        h("div", { class: "title" }, h("span", { class: `pill decision-${d.status}` }, d.status === "proposed" ? "open" : d.status), " ", d.question),
        h("div", { class: "sub" },
          chosen && d.status !== "proposed" ? h("strong", {}, `→ ${chosen} · `) : null,
          who, " · in ", h("span", { class: "decision-doc" }, docTitle(d.doc)), d.goal ? ` · ${goalName(d.goal)}` : ""),
        d.why ? h("div", { class: "sub decision-why" }, h("em", {}, "Why: "), d.why) : null),
      d.status === "superseded" && d.supersededBy
        ? h("div", { class: "sub decision-superseded" }, "Superseded by ",
          h("a", { href: `#/docs/${replacement?.doc ?? d.doc}?decision=${d.supersededBy}`, "data-superseded-by": d.supersededBy }, replacement ? `“${replacement.question}”` : "a newer decision"),
          replacement?.decidedAt ? ` ${ago(replacement.decidedAt)}` : "")
        : null,
      madeFrom(d),
      h("button", { class: "btn ghost decision-history-toggle", type: "button", "aria-expanded": String(showing), onclick: () => {
        if (showing) opened.delete(d.id); else { opened.add(d.id); send({ type: "decision.log", id: d.id }); }
        location.hash = location.hash; // nudge a render
        window.dispatchEvent(new HashChangeEvent("hashchange"));
      } }, showing ? "Hide history" : "History"),
      showing ? h("ol", { class: "decision-history" }, (log ?? []).map((e) =>
        h("li", {}, h("span", { class: "mono" }, `#${e.seq}`), ` ${e.action} by @${e.by}${e.agent ? ` (${e.agent})` : ""} · ${new Date(e.at).toLocaleString()}`, e.why ? ` — “${e.why}”` : ""))) : null);
  }

  return { view };
}
